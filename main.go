package main

import (
	"context"
	"fmt"
	"log"
	"math/big"
	"math/rand"
	"os"
	"time"

	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/ethereum/go-ethereum/suave/sdk"
	"github.com/flashbots/suapp-examples/framework"
	"github.com/joho/godotenv"
)

const (
	SEPOLIA_CHAIN_ID       = 11155111
	SUAVE_TESTNET_CHAIN_ID = 16813125
	LOCAL_TESTCHAIN_ID     = 1234321
)

func deployContract(_path string) *framework.Contract {
	return fr.Suave.DeployContract(_path)
}

// TODO: does not work so far for constructor with args, need to uncomment constructor in contract
func deployContractWithConstructor(SuaveDevAccount *framework.PrivKey, params ...interface{}) *framework.Contract { //(common.Address, *types.Transaction, *bind.BoundContract) {
	artifact, err := framework.ReadArtifact(path)
	checkError(err)

	// Pack the constructor parameters
	constructorParams, err := artifact.Abi.Pack("", params...)
	checkError(err)
	newClient := sdk.NewClient(SuaveClient.Client(), SuaveDevAccount.Priv, fr.KettleAddress)
	txnResult, err := sdk.DeployContract(append(artifact.Code, constructorParams...), newClient)
	checkError(err)

	receipt, err := txnResult.Wait()
	checkError(err)
	if receipt.Status == 0 {
		panic(fmt.Errorf("transaction failed"))
	}
	log.Printf("deployed contract at %s", receipt.ContractAddress.Hex())
	contract := sdk.GetContract(receipt.ContractAddress, artifact.Abi, newClient)
	// for framework.CreateContract to work you have to adapt the framework.go file and add:
	/* func CreateContract(_address common.Address, _sdkClient *sdk.Client, _kettleAddress common.Address, _abi *abi.ABI, _contract *sdk.Contract) *Contract {
		return &Contract{addr: _address, clt: _sdkClient, kettleAddr: _kettleAddress, Abi: _abi, contract: _contract}
	} */
	return framework.CreateContract(receipt.ContractAddress, newClient, fr.KettleAddress, artifact.Abi, contract)
}

/*
* access a public field of the contract
* @param1 contract @param2 name of the public field
 */
func getFieldFromContract(contract *framework.Contract, fieldName string) []interface{} {
	res := contract.Call(fieldName, nil)
	fmt.Println(fieldName, " : ", res)
	return res
}

// only prints latest emitted event; flag to request new  event
func printContractInfo(contract *framework.Contract) {
	receipt := contract.SendConfidentialRequest("printInfo", nil, nil)
	event, err := contract.Abi.Events["AuctionOpened"].ParseLog(receipt.Logs[0])
	checkError(err)
	fmt.Println("Contract address:", event["contractAddr"])
	fmt.Println("End Timestamp: ", event["endTimestamp"])
	fmt.Println("Number of Bidders: ", event["bidderAmount"])
}

func registerRPC(contract *framework.Contract) {
	confidentialInput := "https://sepolia.infura.io/v3/93302e94e89f41afafa250f8dce33086"
	receipt := contract.SendConfidentialRequest("registerRPCOffchain", []interface{}{L1chainID}, []byte(confidentialInput))
	event, err := contract.Abi.Events["RPCEndpointUpdated"].ParseLog(receipt.Logs[0])
	checkError(err)
	fmt.Println("RPC Point on contract updated to chainID:", event["chainId"])
}

func registerTestRPC(contract *framework.Contract) {
	confidentialInput := "http://localhost:8555"
	chainID := big.NewInt(LOCAL_TESTCHAIN_ID)
	receipt := contract.SendConfidentialRequest("registerRPCOffchain", []interface{}{chainID}, []byte(confidentialInput))
	event, err := contract.Abi.Events["RPCEndpointUpdated"].ParseLog(receipt.Logs[0])
	checkError(err)
	fmt.Println("RPC Point on contract updated to chainID:", event["chainId"])
}

func getBiddingAddress(contract *framework.Contract) string {
	receipt := contract.SendConfidentialRequest("getBiddingAddress", nil, nil)
	event, err := contract.Abi.Events["BiddingAddress"].ParseLog(receipt.Logs[0])
	checkError(err)
	fmt.Println("Owner of Bidding address:", event["owner"])
	fmt.Println("Encoded L1 address:", event["encodedL1Address"])
	return event["encodedL1Address"].(string)
}

func createAccount() *framework.PrivKey {
	newAccountPrivKey := framework.GeneratePrivKey()
	log.Printf("Created Address at: %s", newAccountPrivKey.Address().Hex())
	fundBalance := big.NewInt(50000000000000) // fund 50000 GWEI
	fmt.Println("Funding the L1 account with balance: ", fundBalance)
	fundL1Account(newAccountPrivKey.Address(), fundBalance)
	fundBalance = big.NewInt(10000000000000000)
	fmt.Println("Funding the Suave account with balance: ", fundBalance)
	fundSuaveAccount(newAccountPrivKey.Address(), fundBalance)
	return newAccountPrivKey
}

func fundSuaveAccount(account common.Address, fundBalance *big.Int) {
	err := fr.Suave.FundAccount(account, fundBalance)
	checkError(err)
	if bal, err := SuaveClient.BalanceAt(context.Background(), account, nil); err != nil {
		log.Fatal(err)
	} else {
		log.Printf("Balance of account on Suave chain: %s:\t%t", account, bal)
	}
}

// make L1 Transaction
// @params: privKey of sender; value of ETH transfer, to Address of receiver
func makeTransaction(privKey *framework.PrivKey, value *big.Int, to common.Address) {
	gasPrice, err := L1client.SuggestGasPrice(context.Background())
	checkError(err)
	nonce, err := L1client.PendingNonceAt(context.Background(), privKey.Address())
	checkError(err)
	tip := big.NewInt(1500000000)
	currentNonce, err := L1client.NonceAt(context.Background(), privKey.Address(), nil)
	checkError(err)
	gasFee := big.NewInt(50000000).Add(gasPrice, tip)
	/* 	fmt.Printf("Current nonce: %d and nonce: %f\n", currentNonce, nonce)
	   	fmt.Printf("GasTipCap %d\t gasFeeCap %e\n", gasPrice, gasFee) */
	if nonce != currentNonce {
		nonce = currentNonce // override slow transaction
	}
	txnLegacy := &types.DynamicFeeTx{
		Nonce:      nonce,
		Value:      value,
		To:         &to,
		Data:       nil,
		Gas:        21000,
		ChainID:    L1chainID,
		GasTipCap:  tip,    // TODO ADAPT PRICES 1,5 GWEI
		GasFeeCap:  gasFee, //
		AccessList: nil,
	}
	//TODO HERE
	tx := types.NewTx(txnLegacy)
	signer := types.LatestSignerForChainID(L1chainID)
	signedTx, err := types.SignTx(tx, signer, privKey.Priv)
	checkError(err)
	err = L1client.SendTransaction(context.Background(), signedTx)
	checkError(err)

	for {
		_, pending, err := L1client.TransactionByHash(context.Background(), signedTx.Hash())
		if err != nil {
			fmt.Println("Transaction not found yet...")
			time.Sleep(5 * time.Second)
			continue
		}
		if pending {
			fmt.Println("Transaction is pending...")
		} else {
			fmt.Println("Transaction included!")
		}
		break
	}
	_, err = bind.WaitMined(context.Background(), L1client, signedTx)
	checkErrorWithMessage(err, "Error waiting for transaction to be mined: ")
}

// helper functionality
func printSuaveChainInfoComplete() {
	blockNumber, err := SuaveClient.BlockNumber(context.Background())
	printChainInfo("Suave Chain Block Count: ", blockNumber, err)
	chainID, err := SuaveClient.ChainID(context.Background())
	printChainInfo("Suave Chain ID: ", chainID, err)
	peerCount, err := SuaveClient.PeerCount(context.Background())
	printChainInfo("Suave Peer count: ", peerCount, err)
}
func printL1ChainInfoComplete() {
	blockNumber, err := L1client.BlockNumber(context.Background())
	printChainInfo("L1 Chain Block Count: ", blockNumber, err)
	chainID, err := L1client.ChainID(context.Background())
	printChainInfo("L1 Chain ID: ", chainID, err)
	peerCount, err := L1client.PeerCount(context.Background())
	printChainInfo("L1 Peer count: ", peerCount, err)
}

func printChainInfo(mes string, out interface{}, err error) {
	checkError(err)
	fmt.Println(mes, out)
}

func placeBid(privKey *framework.PrivKey, bidContract *framework.Contract) {
	// SUAVE: get BiddingAddress by calling contract on suave chain
	rand.Seed(time.Now().UnixNano())
	toAddress := common.HexToAddress(getBiddingAddress(bidContract))
	amount := big.NewInt(1000000000 + int64(rand.Intn(2000))) // (1 GWEI + ~2000)
	// L1: create tx to send money
	fmt.Println("Place bid with amount ", amount, " to adddress ", toAddress)
	makeTransaction(privKey, amount, toAddress)
	fmt.Println(privKey.Address(), " bid ", amount, " to ", toAddress)
	/* // rlp encode tx not needed anymore?
	 	// now RLP encode Tx and send to contract
		encodedTx, err := rlp.EncodeToBytes(tx)
		checkError(err)
		receipt := bidContract.SendConfidentialRequest("placeBid", nil, encodedTx)
		event, err := bidContract.Abi.Events["BidPlacedEvent"].ParseLog(receipt.Logs[0])
		checkError(err)
		fmt.Println("Bid placed by:", event["bidder"], " with amount: ", event["value"])
	*/
}

func fundL1Account(to common.Address, value *big.Int) error {
	funderAddr := L1DevAccount.Address()

	balance, err := L1client.BalanceAt(context.Background(), funderAddr, nil)
	if err != nil {
		return err
	}

	log.Printf("funding account %s with %s", to.Hex(), value.String())
	log.Printf("funder %s %s", funderAddr.Hex(), balance.String())
	makeTransaction(L1DevAccount, value, to)
	// check Balance
	balance, err = L1client.BalanceAt(context.Background(), to, nil)
	checkError(err)
	if balance.Cmp(value) != 0 {
		return fmt.Errorf("failed to fund account")
	} else {
		log.Printf("Balance of account on L1 chain: %s:\t%t", to, balance)
	}
	return nil
}

func printRPCEndpoint(contract *framework.Contract) {
	receipt := contract.SendConfidentialRequest("printRPCEndpoint", []interface{}{L1chainID}, nil)
	event, err := contract.Abi.Events["RPCEndpoint"].ParseLog(receipt.Logs[0])
	checkError(err)
	fmt.Println("Check contract conf store RPC Endpoint chain ID:", event["chainId"])
	fmt.Println("Check contract conf store RPC Endpoint endpoint URL:", event["endpointURL"])
}

func endAuction(contract *framework.Contract) {
	/* 	balance, err := client.BalanceAt(context.Background(), fr.KettleAddress, nil)
	   	if err != nil {
	   		log.Fatalf("Failed to get account balance: %v", err)
	   	}
	   	fmt.Printf("Deployer account balance: %s wei\n", balance.String()) */
	receipt := contract.SendConfidentialRequest("endAuction", nil, nil)
	//SendTransactionWithIncreasedGas("endAuction", nil, nil)
	event, err := contract.Abi.Events["WinnerAddress"].ParseLog(receipt.Logs[0])
	checkError(err)
	fmt.Println("AND THE WINNER IS:", event["winner"], " with the bid of: ", event["amount"])
}

func revealBidders(contract *framework.Contract) []common.Address {
	receipt := contract.SendConfidentialRequest("revealBidders", nil, nil)
	bidderList := []common.Address{}
	for i := 0; i < len(receipt.Logs); i++ {
		event, err := contract.Abi.Events["RevealBiddingAddress"].ParseLog(receipt.Logs[i])
		checkError(err)
		fmt.Println("Revealed L1 address:", event["bidder"])
		bidderList = append(bidderList, event["bidder"].(common.Address))
	}
	return bidderList
}

// called before main()
func init() {
	var err error
	SuaveClient, err = ethclient.Dial("http://localhost:8545")
	checkError(err)
	L1client, err = ethclient.Dial("https://sepolia.infura.io/v3/93302e94e89f41afafa250f8dce33086")
	checkError(err)
	fr = framework.New(framework.WithL1())
	err = godotenv.Load()
	checkErrorWithMessage(err, "Error loading .env file: ")
	// For private local L1 testnet uncomment
	//suavePrivKey := os.Getenv("SUAVE_DEV_PRIVATE_KEY")
	//L1DevAccount = framework.NewPrivKeyFromHex(suavePrivKey)
	//L1chainID = *big.NewInt(LOCAL_TESTCHAIN_ID)

	privKeySuave := os.Getenv("SUAVE_DEV_PRIVATE_KEY")
	if privKeySuave == "" {
		log.Fatal("ENTER PRIVATE Suave KEY in .env file!")
	}
	SuaveDevAccount = framework.NewPrivKeyFromHex(privKeySuave)
	// --------------------------------------
	// For Sepolia L1 testnet
	L1chainID = big.NewInt(SEPOLIA_CHAIN_ID)
	privKey := os.Getenv("L1_PRIVATE_KEY")
	if privKey == "" {
		log.Fatal("ENTER PRIVATE L1 KEY in .env file!")
	}
	L1DevAccount = framework.NewPrivKeyFromHex(privKey)
	checkError(err)
}

var SuaveClient *ethclient.Client
var L1client *ethclient.Client
var L1chainID *big.Int
var L1DevAccount *framework.PrivKey
var SuaveDevAccount *framework.PrivKey

var path = "SealedAuction.sol/SealedAuction.json"
var fr *framework.Framework

func main() {
	pause := false
	if pause {
		mainWithPause()
		return
	}
	fmt.Println("1. Deploy Sealed Auction contract")
	//TODO: adapt inputs to something interesting (not yet used)
	auctionTimeInDays, chainId := big.NewInt(1), big.NewInt(420)                                    // chainId overridden by registerrpcendpoint
	contract := deployContractWithConstructor(SuaveDevAccount, auctionTimeInDays, "MyNFT", chainId) // TODO: rpc handling in constructor does not work
	//var contract = deployContract(path)
	getFieldFromContract(contract, "auctionEndTime")

	fmt.Println("2. Register RPC endpoint")
	registerRPC(contract)
	//registerTestRPC(contract)
	printRPCEndpoint(contract)

	fmt.Println("3. Print Contract Info")
	printContractInfo(contract)

	fmt.Println("4. Print Suave Chain Info")
	printSuaveChainInfoComplete()

	fmt.Println("4. Print L1 Chain Info")
	printL1ChainInfoComplete()

	fmt.Println("5. Create new account & bid")
	// adapt sdk.go to solve the running out of gas
	num_accounts := 2 // adapt accounts to be created here (must be <5 as 5 bidders makes endAuction() run out of gas)
	bidders := make([]*framework.PrivKey, 0)
	for i := 0; i < num_accounts; i++ {
		bidders = append(bidders, createAccount()) // appends newly created account (has funds on Suave and L1)
		bidContract := contract.Ref(bidders[i])
		placeBid(bidders[i], bidContract)
	}

	fmt.Println("6. Print Contract Info again")
	printContractInfo(contract)

	fmt.Println("7. Reveal bidders")
	_ = revealBidders(contract)
	/* 	if num_accounts < 5 {
		fmt.Println("8. End auction")
		endAuction(contract)
	}
	*/
}

func mainWithPause() {
	var input = ""
	fmt.Scanln(&input)
	fmt.Println("1. Deploy Sealed Auction contract")
	//TODO: contract := deployContractWithConstructor()
	var contract = deployContract(path)
	fmt.Scanln(&input)

	fmt.Println("2. Register RPC endpoint")
	/* TODO: uncomment this registerRPC(contract) */
	registerTestRPC(contract)
	printRPCEndpoint(contract)
	fmt.Scanln(&input)

	fmt.Println("3. Print Contract Info")
	printContractInfo(contract)
	fmt.Scanln(&input)

	fmt.Println("4. Print Suave Chain Info")
	printSuaveChainInfoComplete()
	fmt.Scanln(&input)

	fmt.Println("4. Print L1 Chain Info")
	printL1ChainInfoComplete()
	fmt.Scanln(&input)

	fmt.Println("5. Create new account & bid")
	num_accounts := 2 // adapt accounts to be created here
	bidders := make([]*framework.PrivKey, 0)
	for i := 0; i < num_accounts; i++ {
		bidders = append(bidders, createAccount()) // appends newly created account (has funds on Suave and L1)
		bidContract := contract.Ref(bidders[i])
		placeBid(bidders[i], bidContract)
	}
	fmt.Scanln(&input)

	fmt.Println("6. Print Contract Info again")
	printContractInfo(contract)
	fmt.Scanln(&input)

	fmt.Println("7. Reveal bidders")
	_ = revealBidders(contract)
	fmt.Scanln(&input)

	/*
		 	if num_accounts < 5 {
				fmt.Println("8. End auction")
				endAuction(contract)
			}
	*/
}

func checkError(err error) {
	if err != nil {
		panic(err)
	}
}

func checkErrorWithMessage(err error, mes string) {
	if err != nil {
		log.Fatal(mes, err)
	}
}
