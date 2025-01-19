package main

import (
	"bytes"
	"context"
	"fmt"
	"io/ioutil"
	"log"
	"math/big"
	"math/rand"
	"net/http"
	"os"
	"time"

	"suave/whisperwins/framework"

	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/ethereum/go-ethereum/suave/sdk"
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
func deployContractWithConstructor(_path string, SuaveDevAccount *framework.PrivKey, params ...interface{}) *framework.Contract { //(common.Address, *types.Transaction, *bind.BoundContract) {
	artifact, err := framework.ReadArtifact(_path)
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
	//sdk.SetDefaultGasLimit(30000000)
	receipt := contract.SendConfidentialRequest("printInfo", nil, nil)
	if len(receipt.Logs) > 0 {
		event, err := contract.Abi.Events["AuctionInfo"].ParseLog(receipt.Logs[0])
		checkError(err)
		fmt.Println("Auctioneer SUAVE Address:", event["auctioneerSUAVE"])
		fmt.Println("NFT Holding Address:", event["nftHoldingAddress"])
		fmt.Println("NFT Contract Address:", event["nftContract"])
		fmt.Println("Token ID:", event["tokenId"])
		fmt.Println("Auction End Time:", event["auctionEndTime"])
		fmt.Println("Minimal Bid:", event["minimalBid"])
		fmt.Println("Auction Has Started:", event["auctionHasStarted"])
		fmt.Println("Final Block:", event["finalBlockNumber"])
		fmt.Println("Auction Winner:", event["winner"])
		fmt.Println("Winning Bid:", event["winningBid"])
		fmt.Println("ETH Block Number:", event["ethBlockNumber"])
	}

}

func registerRPC(contract *framework.Contract) {
	var confidentialInput string
	if useLiveNet {
		confidentialInput = "https://sepolia.infura.io/v3/93302e94e89f41afafa250f8dce33086"
	} else {
		confidentialInput = "http://localhost:8555" // if local testchain
	}
	receipt := contract.SendConfidentialRequest("registerRPCOffchain", []interface{}{L1chainID}, []byte(confidentialInput))
	event, err := contract.Abi.Events["RPCEndpointUpdated"].ParseLog(receipt.Logs[0])
	checkError(err)
	fmt.Println("RPC Point on contract updated to chainID:", event["chainId"])
}

func getBiddingAddress(contract *framework.Contract) string {
	receipt := contract.SendConfidentialRequest("getBiddingAddress", nil, nil)
	event, err := contract.Abi.Events["EncBiddingAddress"].ParseLog(receipt.Logs[0])
	checkError(err)
	fmt.Println("Owner of Bidding address:", event["owner"])
	fmt.Println("Encrypted L1 address:", event["encryptedL1Address"])
	return event["encryptedL1Address"].(string)
}

func createAccount() *framework.PrivKey {
	newAccountPrivKey := framework.GeneratePrivKey()
	log.Printf("Created Address at: %s", newAccountPrivKey.Address().Hex())
	fundBalance := big.NewInt(5000000000000000) // fund 5.000.000 GWEI
	if !useLiveNet {
		fundBalance = big.NewInt(10000000000000000) // fund more on local testnet
	}
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
	tip := big.NewInt(1500000000) // 1,5 Gwei

	gasFee := big.NewInt(50000000).Add(gasPrice, tip)
	/* 	fmt.Printf("Current nonce: %d and nonce: %f\n", currentNonce, nonce)
	   	fmt.Printf("GasTipCap %d\t gasFeeCap %e\n", gasPrice, gasFee) */

	// for underpriced uncomment hereUnderpriced here
	/* 	nonce, err = L1client.NonceAt(context.Background(), privKey.Address(), nil)
	checkError(err)
	if nonce != currentNonce {
		nonce = currentNonce // override slow transaction (only use when tx is stuck)
	} */
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
			continue
		}
		if pending {
			fmt.Println("Transaction is pending...")
		} else {
			fmt.Println("Transaction included!")
			break
		}
		time.Sleep(5 * time.Second)
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
	//rand.Seed(time.Now().UnixNano())
	toAddress := common.HexToAddress(getBiddingAddress(bidContract))
	amount := big.NewInt(4000000000000000 + int64(rand.Intn(10000))) // (4.000.000 GWEI + ~10000)
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
	gasPrice, err := L1client.SuggestGasPrice(context.Background())
	checkError(err)
	header, err := L1client.HeaderByNumber(context.Background(), nil)
	checkError(err)

	log.Printf("Consisting of value: %s, gasPrice: %s*21000 = %s, baseFee: %s", value, gasPrice, big.NewInt(0).Mul(gasPrice, big.NewInt(21000)), header.BaseFee)
	log.Printf("funder %s %s", funderAddr.Hex(), balance.String())
	value.Add(value, header.BaseFee)         // add baseFee from last block
	value.Add(value, big.NewInt(1000000000)) // plus one GWEI for priority
	gasPrice.Mul(gasPrice, big.NewInt(21000))
	value.Add(value, gasPrice) // add gascosts
	log.Printf("funding account %s with %s.", to.Hex(), value.String())
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

func startAuction(contract *framework.Contract) {
	receipt := contract.SendConfidentialRequest("startAuction", nil, nil)
	for i := 0; i < len(receipt.Logs); i++ {
		if receipt.Logs[i].Topics[0] == contract.Abi.Events["AuctionOpened"].ID {
			event, err := contract.Abi.Events["AuctionOpened"].ParseLog(receipt.Logs[i])
			checkError(err)
			fmt.Println("Contract Address:", event["contractAddr"])
			fmt.Println("NFT Contract Address:", event["nftContractAddress"])
			fmt.Println("NFT Token ID:", event["nftTokenId"])
			fmt.Println("End Timestamp:", event["endTimestamp"])
			fmt.Println("Minimal Bidding Amount:", event["minimalBiddingAmount"])
		}
	}
}

// TODO: Remove this
func startAuctionTest(contract *framework.Contract) {
	receipt := contract.SendConfidentialRequest("startAuctionTest", nil, nil)
	event, err := contract.Abi.Events["AuctionOpened"].ParseLog(receipt.Logs[0])
	checkError(err)
	fmt.Println("Contract Address:", event["contractAddr"])
	fmt.Println("NFT Contract Address:", event["nftContractAddress"])
	fmt.Println("NFT Token ID:", event["nftTokenId"])
	fmt.Println("End Timestamp:", event["endTimestamp"])
	fmt.Println("Minimal Bidding Amount:", event["minimalBiddingAmount"])
}

func endAuctionDeprecated(contract *framework.Contract) {
	/* 	balance, err := client.BalanceAt(context.Background(), fr.KettleAddress, nil)
	   	if err != nil {
	   		log.Fatalf("Failed to get account balance: %v", err)
	   	}
	   	fmt.Printf("Deployer account balance: %s wei\n", balance.String()) */
	//sdk.SetDefaultGasLimit(uint64(0))
	receipt := contract.SendConfidentialRequest("endAuction", nil, nil)
	fmt.Println("GAS USED FOR TX", receipt.GasUsed)
	fmt.Println("Effective gas price FOR TX", receipt.EffectiveGasPrice)
	fmt.Println("CUMULATIVE GAS USED FOR TX", receipt.CumulativeGasUsed)

	//SendTransactionWithIncreasedGas("endAuction", nil, nil)
	if receipt.Status == types.ReceiptStatusFailed {
		log.Fatal("End Auction call failed")
	}
	fmt.Println("End auction results:")
	if receipt.Logs[0].Topics[0] == contract.Abi.Events["NoBidder"].ID {
		_, err := contract.Abi.Events["NoBidder"].ParseLog(receipt.Logs[0])
		checkError(err)
		fmt.Println("NO WINNER AS NO BIDS WERE REGISTERED")
	} else if receipt.Logs[0].Topics[0] == contract.Abi.Events["WinnerAddress"].ID {
		event, err := contract.Abi.Events["WinnerAddress"].ParseLog(receipt.Logs[0])
		checkError(err)
		fmt.Println("AND THE WINNER IS:", event["winner"])
	} else if receipt.Logs[0].Topics[0] == contract.Abi.Events["AuctionEndedAmbigious"].ID {
		event, err := contract.Abi.Events["AuctionEndedAmbigious"].ParseLog(receipt.Logs[0])
		checkError(err)
		fmt.Println("Bidding ended in a draw with: ", event["numberMaxBidders"], "bidders having the same bid of: ", event["bidAmount"])
	} else {
		log.Fatal("SOMETHING WENT WRONG. Check endAuction functionality")
	}

}

func endAuction(contract *framework.Contract) {

}

func revealBidders(contract *framework.Contract) []common.Address {
	sdk.SetDefaultGasLimit(uint64(0))
	receipt := contract.SendConfidentialRequest("revealBidders", nil, nil)
	if receipt.Status == types.ReceiptStatusFailed {
		panic("Revealing Bidders tx Failed")
	}
	bidderList := []common.Address{}
	fmt.Println("Number of bidders: ", len(receipt.Logs))
	for i := 0; i < len(receipt.Logs); i++ {
		if receipt.Logs[i].Topics[0] == contract.Abi.Events["RevealBiddingAddress"].ID {
			event, err := contract.Abi.Events["RevealBiddingAddress"].ParseLog(receipt.Logs[i])
			checkError(err)
			fmt.Println("Revealed L1 address:", event["bidderL1"], " & Suave Addresse: ", event["bidderSuave"])
			bidderList = append(bidderList, event["bidderL1"].(common.Address))
		}
	}
	return bidderList
}

// called before main
func init() {
	var err error
	SuaveClient, err = ethclient.Dial("http://localhost:8545")
	checkError(err)
	fr = framework.New(framework.WithL1())
	err = godotenv.Load()
	checkErrorWithMessage(err, "Error loading .env file: ")

	privKeySuave := os.Getenv("SUAVE_DEV_PRIVATE_KEY")
	if privKeySuave == "" {
		log.Fatal("ENTER PRIVATE Suave KEY in .env file!")
	}
	SuaveDevAccount = framework.NewPrivKeyFromHex(privKeySuave)

	if useLiveNet { // For Sepolia L1 testnet
		L1client, err = ethclient.Dial("https://sepolia.infura.io/v3/93302e94e89f41afafa250f8dce33086")
		checkError(err)
		L1chainID = big.NewInt(SEPOLIA_CHAIN_ID)
		privKey := os.Getenv("L1_PRIVATE_KEY")
		if privKey == "" {
			log.Fatal("ENTER PRIVATE L1 KEY in .env file!")
		}
		L1DevAccount = framework.NewPrivKeyFromHex(privKey)
		checkError(err)
	} else {
		// For private local L1 testnet uncomment4
		L1DevAccount = framework.NewPrivKeyFromHex(privKeySuave) // already given funds on L1 local testnet via genesis block
		L1chainID = big.NewInt(LOCAL_TESTCHAIN_ID)
		L1client, err = ethclient.Dial("http://localhost:8555")
		checkError(err)

	}

}

var SuaveClient *ethclient.Client
var L1client *ethclient.Client
var L1chainID *big.Int
var L1DevAccount *framework.PrivKey
var SuaveDevAccount *framework.PrivKey

var path = "SealedAuction.sol/SealedAuction.json"
var fr *framework.Framework

var useLiveNet = false

func main() {
	pause := false
	if pause {
		//mainWithPause()
		return
	}
	fmt.Println("0. Setup: Deploy Oracle")
	chainIDL1 := big.NewInt(LOCAL_TESTCHAIN_ID)
	oracle := deployContractWithConstructor("Oracle.sol/Oracle.json", SuaveDevAccount, chainIDL1)
	api_key := os.Getenv("ALCHEMY_API_KEY")
	if api_key == "" {
		log.Fatal("ENTER PRIVATE Suave KEY in .env file!")
	}
	receipt := oracle.SendConfidentialRequest("registerApiKeyOffchain", nil, []byte(api_key))
	if receipt.Status == types.ReceiptStatusSuccessful {
		fmt.Println("API Key registered")
	}

	fmt.Println("1. Deploy Sealed Auction contract")
	//TODO: adapt inputs to something interesting (not yet used)
	auctionInSeconds := int64(10)
	auctionEndTime := big.NewInt(int64(time.Now().Unix() + auctionInSeconds))
	nftTokenID, minimalBiddingAmount := big.NewInt(420), big.NewInt(1000000000)
	nftContractAddress := L1DevAccount.Address()
	contract := deployContractWithConstructor(path, SuaveDevAccount, nftContractAddress, nftTokenID, auctionEndTime, minimalBiddingAmount, oracle.Raw().Address()) // TODO: rpc handling in constructor does not work
	time.AfterFunc(time.Duration(auctionInSeconds)*time.Second, func() {
		fmt.Println("Auction ended!")
	})
	getFieldFromContract(contract, "auctionHasStarted")

	fmt.Println("3. Print Contract Info")
	printContractInfo(contract)

	fmt.Println("4. Print Suave Chain Info")
	printSuaveChainInfoComplete()

	fmt.Println("4. Print L1 Chain Info")
	printL1ChainInfoComplete()

	fmt.Println("4.5. Start Auction")
	startAuction(contract)
	//startAuctionTest(contract)
	fmt.Println("5. Create new account & bid")
	num_accounts := 2 // adapt accounts to be created here
	bidders := make([]*framework.PrivKey, 0)
	for i := 0; i < num_accounts; i++ {
		fmt.Println("Creating account #", i)
		bidders = append(bidders, createAccount()) // appends newly created account (has funds on Suave and L1)
		bidContract := contract.Ref(bidders[i])
		placeBid(bidders[i], bidContract)
	}

	/*
		 	fmt.Println("6. Reveal bidders\nWaiting for the auction to end...")
			time.Sleep(time.Duration(auctionInSeconds) * time.Second) //TODO: fix timing here as block.timestamp is unreliable
			fmt.Println("Current time: ", time.Now().Unix())
			getFieldFromContract(contract, "auctionEndTime")
			biddedAddresses := revealBidders(contract)
	*/
	fmt.Println("7. Waiting for server to reveal bidders...")
	time.Sleep(time.Duration(auctionInSeconds) * time.Second) //TODO: fix timing here as block.timestamp is unreliable
	fmt.Println("Current time: ", time.Now().Unix())
	getFieldFromContract(contract, "auctionEndTime")
	biddedAddresses := revealBidders(contract) // need this to get the contracts but winner should have been determined

	winner := getFieldFromContract(contract, "auctionWinner")[0].(common.Address)

	/* 	fmt.Println("7. Refute winner")
	   	fmt.Println("Claim as winner: ", bidders[1].Address())
	   	receipt = contract.SendConfidentialRequest("refuteWinner", []interface{}{bidders[1].Address()}, nil)
	   	printReceipt(receipt, contract, oracle) */

	fmt.Println("8. Print Contract Info final")
	sdk.SetDefaultGasLimit(3000000)
	printContractInfo(contract)
	sdk.SetDefaultGasLimit(0)

	fmt.Println("9. Return funds")
	for i := 0; i < num_accounts; i++ {
		if biddedAddresses[i] == winner {
			fmt.Println("♛ The address: ", biddedAddresses[i], " won the auction and will not get their funds back ♛")
			continue
		}
		balance, err := L1client.BalanceAt(context.Background(), biddedAddresses[i], nil)
		checkError(err)
		fmt.Println("BEFORE Refund bid: ", biddedAddresses[i], " has balance of ", balance)
		bidContract := contract.Ref(bidders[i])
		fmt.Println("Get funds back for Suave Address:", bidders[i].Address())
		_ = bidContract.SendConfidentialRequest("refundBid", []interface{}{bidders[i].Address()}, nil)
		balance, err = L1client.BalanceAt(context.Background(), biddedAddresses[i], nil)
		checkError(err)
		fmt.Println("AFTER Refund bid: ", biddedAddresses[i], " has balance of ", balance)
	}
	fmt.Println("10. Return winning bid to auctioneer")
	balance, err := L1client.BalanceAt(context.Background(), winner, nil)
	checkError(err)
	fmt.Println("BEFORE returning the winning bid (Winning Bid Address): ", winner, " has balance of ", balance)
	balance, err = L1client.BalanceAt(context.Background(), SuaveDevAccount.Address(), nil)
	checkError(err)
	fmt.Println("BEFORE returning the winning bid (Auctioneer Address): ", SuaveDevAccount.Address(), " has balance of ", balance)
	getFieldFromContract(contract, "auctioneerSUAVE")
	fmt.Println("CAlling with :", SuaveDevAccount.Address())
	contract = contract.Ref(SuaveDevAccount)
	receipt = contract.SendConfidentialRequest("claimWinningBid", []interface{}{SuaveDevAccount.Address()}, nil)
	printReceipt(receipt, contract, oracle)
	balance, err = L1client.BalanceAt(context.Background(), winner, nil)
	checkError(err)
	fmt.Println("AFTER returning the winning bid (Winning Bid Address): ", winner, " has balance of ", balance)
	balance, err = L1client.BalanceAt(context.Background(), SuaveDevAccount.Address(), nil)
	checkError(err)
	fmt.Println("AFTER returning the winning bid: (Auctioneer Address) ", SuaveDevAccount.Address(), " has balance of ", balance)
}

func printReceipt(receipt *types.Receipt, contract, oracle *framework.Contract) {
	for i := 0; i < len(receipt.Logs); i++ {
		if receipt.Logs[i].Topics[0] == contract.Abi.Events["testEvent"].ID {
			event, err := contract.Abi.Events["testEvent"].ParseLog(receipt.Logs[i])
			checkError(err)
			fmt.Println("test:", event["t"])
		} else if receipt.Logs[i].Topics[0] == contract.Abi.Events["WinnerAddress"].ID {
			event, err := contract.Abi.Events["WinnerAddress"].ParseLog(receipt.Logs[i])
			checkError(err)
			fmt.Println("winner:", event["winner"])
		}
	}
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

// TODO: adapt
func helper(contract *framework.Contract) {
	// call server with cronjob now
	url := "http://127.0.0.1:8000/reveal-bidders"
	day := 1
	payload := []byte(fmt.Sprintf(`{"contract":"%s", "timeout":"%d"}`, contract.Raw().Address().Hex(), day))

	// Make the POST request
	resp, err := http.Post(url, "application/json", bytes.NewBuffer(payload))
	if err != nil {
		fmt.Println("Error:", err)
		return
	}
	defer resp.Body.Close()
	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		fmt.Println("Error reading response:", err)
		return
	}

	// Print the response
	fmt.Println("Response from host:")
	fmt.Println(string(body))
}
