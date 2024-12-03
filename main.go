package main

import (
	"context"
	"fmt"
	"log"
	"math/big"
	"math/rand"
	"time"

	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/ethereum/go-ethereum/suave/sdk"
	"github.com/flashbots/suapp-examples/framework"
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
func deployContractWithConstructor(params ...interface{}) *sdk.Contract {
	return nil
	/* artifact, err := framework.ReadArtifact(path)
	if err != nil {
		panic(err)
	}
	privKey, err := crypto.HexToECDSA("91ab9a7e53c220e6210460b65a7a3bb2ca181412a8a7b43ff336b3df1737ce12")
	checkError(err)
	newClient := sdk.NewClient(client.Client(), privKey, fr.KettleAddress)

	fmt.Println("About to deploy Contract ", artifact.Abi.Constructor)
	transactionResult, err := sdk.DeployContract(artifact.Code, newClient)
	checkError(err)
	receipt, err := transactionResult.Wait()
	checkError(err)
	if receipt.Status == 0 {
		panic(fmt.Errorf("transaction failed"))
	}
	log.Printf("deployed contract at %s", receipt.ContractAddress.Hex())
	contract := sdk.GetContract(receipt.ContractAddress, artifact.Abi, newClient)
	transactionResult, err = contract.SendTransaction("printInfo", nil, nil)
	checkError(err)
	receipt, err = transactionResult.Wait()
	checkError(err)
	if receipt.Status == 0 {
		panic(fmt.Errorf("transaction failed"))
	}

	return sdk.GetContract(receipt.ContractAddress, artifact.Abi, newClient)*/
	//--------------------------------------------------------------------- other approach:
	/* auth, err := bind.NewKeyedTransactorWithChainID(privKey, big.NewInt(SUAVE_TESTNET_CHAIN_ID)) // Chain ID for suave testnet
	if err != nil {
		log.Fatalf("Failed to create authorized transactor: %v", err)
	}
	 	gasPrice, err := client.SuggestGasPrice(context.Background())
	   	if err != nil {
	   		log.Fatal(err)
	   	}
	auth.GasLimit = 1000000
	auth.GasPrice = big.NewInt(100000000000)
	balance, err := client.BalanceAt(context.Background(), auth.From, nil)
	if err != nil {
		log.Fatalf("Failed to get account balance: %v", err)
	}
	fmt.Printf("Deployer account balance: %s wei\n", balance.String())

	if balance.Cmp(big.NewInt(0)) == 0 {
		log.Fatal("Account has insufficient funds.")
	}
	address, tx, contract, err := bind.DeployContract(auth, *artifact.Abi, artifact.Code, client, params...)
	if err != nil {
		log.Fatalf("Failed to deploy contract: %v", err)
	}
	fmt.Printf("Contract deployed! Address: %s, Transaction: %s\n", address.Hex(), tx.Hash().Hex())
	fmt.Println("Waiting for contract deployment transaction to be included...")
	_, err = bind.WaitMined(context.Background(), client, tx)
	if err != nil {
		log.Fatalf("Error waiting for contract deployment transaction to be included: %v", err)
	}
	fmt.Println("Address: ", address)
	receipt, err := client.TransactionReceipt(context.Background(), tx.Hash())
	if err != nil {
		log.Fatalf("Failed to get transaction receipt: %v", err)
	}

	if receipt.Status != 1 {
		log.Fatalf("Contract deployment failed, status: %d", receipt.Status)
	} else {
		fmt.Println("Contract deployment successful!")
	}
	err = contract.Call(nil, nil, "printInfo")
	if err != nil {
		log.Fatalf("Error: %v", err)
	}
	return nil */
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
	chainID := big.NewInt(SEPOLIA_CHAIN_ID)
	receipt := contract.SendConfidentialRequest("registerRPCOffchain", []interface{}{chainID}, []byte(confidentialInput))
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
	fundBalance := big.NewInt(1000000000000000000)
	fundL1Account(newAccountPrivKey.Address(), fundBalance)
	fundSuaveAccount(newAccountPrivKey.Address(), fundBalance)
	return newAccountPrivKey
}

func fundSuaveAccount(account common.Address, fundBalance *big.Int) {
	err := fr.Suave.FundAccount(account, fundBalance)
	checkError(err)
	checkError(err)
	if bal, err := client.BalanceAt(context.Background(), account, nil); err != nil {
		log.Fatal(err)
	} else {
		log.Printf("Balance of account on Suave chain: %s:\t%t", account, bal)
	}
}

// TODO: unused! adapt to something useful
func makeTransaction(privKey *framework.PrivKey) {
	newClient := sdk.NewClient(client.Client(), privKey.Priv, fr.KettleAddress)
	gas := big.NewInt(10000)
	gasPrice, err := client.SuggestGasPrice(context.Background())
	checkError(err)
	nonce, err := client.PendingNonceAt(context.Background(), newClient.Addr())
	checkError(err)
	txn := &types.LegacyTx{
		Nonce:    nonce,
		To:       &fr.KettleAddress,
		Value:    gas,
		Gas:      10000000,
		GasPrice: gasPrice,
		Data:     nil,
	}
	res, err := newClient.SendTransaction(txn)
	checkError(err)
	fmt.Println("Hash of Transaction: ", res.Hash())
}

// helper functionality
func printSuaveChainInfoComplete() {
	blockNumber, err := client.BlockNumber(context.Background())
	printChainInfo("Suave Chain Block Count: ", blockNumber, err)
	chainID, err := client.ChainID(context.Background())
	printChainInfo("Suave Chain ID: ", chainID, err)
	peerCount, err := client.PeerCount(context.Background())
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
	gasPrice, err := client.SuggestGasPrice(context.Background())
	checkError(err)
	toAddress := common.HexToAddress(getBiddingAddress(bidContract))
	amount := big.NewInt(10000000000 + int64(rand.Intn(2000))) // 1 ETH example

	// L1: create tx to send money
	tx, err := fr.L1.SignTx(privKey, &types.LegacyTx{
		To:       &toAddress,
		Value:    amount,
		Gas:      21000,
		GasPrice: gasPrice.Add(gasPrice, big.NewInt(5000000000)),
	})
	checkError(err)
	err = L1client.SendTransaction(context.Background(), tx)
	checkError(err)
	_, err = bind.WaitMined(context.Background(), L1client, tx)
	checkErrorWithMessage(err, "Error waiting for transaction to be mined: ")
	fmt.Println(privKey.Address(), " bid ", amount, " to ", toAddress)
	/*
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
	funderAddr := localDevAccount.Address()

	balance, err := L1client.BalanceAt(context.Background(), funderAddr, nil)
	if err != nil {
		return err
	}

	log.Printf("funding account %s with %s", to.Hex(), value.String())
	log.Printf("funder %s %s", funderAddr.Hex(), balance.String())
	_, err = L1client.SuggestGasPrice(context.Background())
	checkError(err)
	nonce, err := L1client.PendingNonceAt(context.Background(), funderAddr)
	checkError(err)
	chainID := big.NewInt(LOCAL_TESTCHAIN_ID)
	txnLegacy := &types.DynamicFeeTx{
		Nonce:      nonce,
		Value:      value,
		To:         &to,
		Data:       nil,
		Gas:        21000,
		ChainID:    chainID,
		GasTipCap:  big.NewInt(2000000000), // 2 Gwei (maxPriorityFeePerGas)
		GasFeeCap:  big.NewInt(5000000000),
		AccessList: nil,
	}

	tx := types.NewTx(txnLegacy)
	signer := types.LatestSignerForChainID(chainID)
	signedTx, err := types.SignTx(tx, signer, localDevAccount.Priv)
	checkError(err)
	err = L1client.SendTransaction(context.Background(), signedTx)
	if err != nil {
		return err
	}
	_, err = bind.WaitMined(context.Background(), L1client, signedTx)
	checkErrorWithMessage(err, "Error waiting for transaction to be mined: ")
	balance, err = L1client.BalanceAt(context.Background(), to, nil)
	checkError(err)
	if balance.Cmp(value) != 0 {
		return fmt.Errorf("failed to fund account")
	}
	checkError(err)
	if bal, err := L1client.BalanceAt(context.Background(), to, nil); err != nil {
		log.Fatal(err)
	} else {
		log.Printf("Balance of account on L1 chain: %s:\t%t", to, bal)
	}
	return nil
}

func printRPCEndpoint(contract *framework.Contract) {
	chainID := big.NewInt(LOCAL_TESTCHAIN_ID) //big.NewInt(SEPOLIA_CHAIN_ID) TODO: uncomment
	receipt := contract.SendConfidentialRequest("printRPCEndpoint", []interface{}{chainID}, nil)
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
	client, err = ethclient.Dial("http://localhost:8545")
	checkError(err)
	L1client, err = ethclient.Dial("http://localhost:8555")
	checkError(err)
	fr = framework.New(framework.WithL1())
	localDevAccount = framework.NewPrivKeyFromHex("6c45335a22461ccdb978b78ab61b238bad2fae4544fb55c14eb096c875ccfc52")
	checkError(err)
}

var client *ethclient.Client
var L1client *ethclient.Client
var localDevAccount *framework.PrivKey
var path = "SealedAuction.sol/SealedAuction.json"
var fr *framework.Framework

func main() {
	pause := false
	if pause {
		mainWithPause()
		return
	}
	fmt.Println("1. Deploy Sealed Auction contract")
	//TODO: contract := deployContractWithConstructor()
	var contract = deployContract(path)

	fmt.Println("2. Register RPC endpoint")
	/* TODO: uncomment this registerRPC(contract) */
	registerTestRPC(contract)
	printRPCEndpoint(contract)

	fmt.Println("3. Print Contract Info")
	printContractInfo(contract)

	fmt.Println("4. Print Suave Chain Info")
	printSuaveChainInfoComplete()

	fmt.Println("4. Print L1 Chain Info")
	printL1ChainInfoComplete()

	fmt.Println("5. Create new account & bid")
	// adapt sdk.go to solve the running out of gas
	num_accounts := 4 // adapt accounts to be created here (must be <5 as 5 bidders makes endAuction() run out of gas)
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
	if num_accounts < 5 {
		fmt.Println("8. End auction")
		endAuction(contract)
	}

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
	num_accounts := 4 // adapt accounts to be created here
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

	if num_accounts < 5 {
		fmt.Println("8. End auction")
		endAuction(contract)
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
