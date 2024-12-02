package main

import (
	"context"
	"fmt"
	"io/ioutil"
	"log"
	"math/big"
	"math/rand"
	"os"
	"time"

	"github.com/ethereum/go-ethereum/accounts/keystore"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/ethereum/go-ethereum/rlp"
	"github.com/ethereum/go-ethereum/suave/sdk"
	"github.com/flashbots/suapp-examples/framework"
)

const (
	SEPOLIA_CHAIN_ID       = 11155111
	SUAVE_TESTNET_CHAIN_ID = 16813125
)

// TODO untested
func createKs() {
	ks := keystore.NewKeyStore("/tmp/suave-dev/keystore", keystore.StandardScryptN, keystore.StandardScryptP)
	password := ""
	account, err := ks.NewAccount(password)
	if err != nil {
		log.Fatal(err)
	}

	fmt.Println(account.Address.Hex()) // 0x20F8D42FB0F667F2E53930fed426f225752453b3
}

// TODO untested
func importKs() {
	entries, err := os.ReadDir("/tmp/suave-dev/keystore")
	if err != nil {
		log.Fatal(err)
	}

	for _, e := range entries {
		fmt.Println(e.Name())
	}
	file := "/tmp/suave-dev/keystore/" + entries[0].Name()
	ks := keystore.NewKeyStore("./tmp", keystore.StandardScryptN, keystore.StandardScryptP)
	jsonBytes, err := ioutil.ReadFile(file)
	if err != nil {
		log.Fatal(err)
	}

	password := ""
	account, err := ks.Import(jsonBytes, password, password)
	if err != nil {
		log.Fatal(err)
	}

	fmt.Println(account.Address.Hex()) // 0x20F8D42FB0F667F2E53930fed426f225752453b3

	if err := os.RemoveAll("./tmp"); err != nil {
		log.Fatal(err)
	}
}

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

func getBiddingAddress(contract *framework.Contract) string {
	receipt := contract.SendConfidentialRequest("getBiddingAddress", nil, nil)
	event, err := contract.Abi.Events["BiddingAddress"].ParseLog(receipt.Logs[0])
	checkError(err)
	fmt.Println("Owner of Bidding address:", event["owner"])
	fmt.Println("Encoded L1 address:", event["encodedL1Address"])
	return event["encodedL1Address"].(string)
}

func createAccount() *framework.PrivKey {
	testAddr := framework.GeneratePrivKey()
	log.Printf("Created Address at: %s", testAddr.Address().Hex())
	fundAccount(testAddr)
	return testAddr
}

func fundAccount(privKey *framework.PrivKey) {
	fundBalance := big.NewInt(100000000000000000)
	if err := fr.Suave.FundAccount(privKey.Address(), fundBalance); err != nil {
		log.Fatal(err)
	} else {
		if bal, err := client.BalanceAt(context.Background(), privKey.Address(), nil); err != nil {
			log.Fatal(err)
		} else {
			log.Printf("Balance of account: %s:\t%t", privKey.Address(), bal)
		}
	}
}

// TODO: adapt to something useful
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
func printChainInfoComplete() {
	blockNumber, err := client.BlockNumber(context.Background())
	printChainInfo("Chain Block Count: ", blockNumber, err)
	chainID, err := client.ChainID(context.Background())
	printChainInfo("Chain ID: ", chainID, err)
	peerCount, err := client.PeerCount(context.Background())
	printChainInfo("Peer count: ", peerCount, err)
}

func printChainInfo(mes string, out interface{}, err error) {
	checkError(err)
	fmt.Println(mes, out)
}

func placeBid(privKey *framework.PrivKey, bidContract *framework.Contract) {
	rand.Seed(time.Now().UnixNano())
	gasPrice, err := client.SuggestGasPrice(context.Background())
	checkError(err)
	toAddress := common.HexToAddress(getBiddingAddress(bidContract))
	amount := big.NewInt(10000000000 + rand.Int63()) // 1 ETH example

	tx, err := fr.Suave.SignTx(privKey, &types.LegacyTx{
		To:       &toAddress,
		Value:    amount,
		Gas:      21000,
		GasPrice: gasPrice.Add(gasPrice, big.NewInt(5000000000)),
	})
	checkError(err)
	// now RLP encode Tx and send to contract
	encodedTx, err := rlp.EncodeToBytes(tx)
	checkError(err)
	receipt := bidContract.SendConfidentialRequest("placeBid", nil, encodedTx)
	event, err := bidContract.Abi.Events["BidPlacedEvent"].ParseLog(receipt.Logs[0])
	checkError(err)
	fmt.Println("Bid placed by:", event["bidder"], " with amount: ", event["value"])
}

func printRPCEndpoint(contract *framework.Contract) {
	chainID := big.NewInt(SEPOLIA_CHAIN_ID)
	receipt := contract.SendConfidentialRequest("printRPCEndpoint", []interface{}{chainID}, nil)
	event, err := contract.Abi.Events["RPCEndpoint"].ParseLog(receipt.Logs[0])
	checkError(err)
	fmt.Println("Check contract conf store RPC Endpoint chain ID:", event["chainId"])
	fmt.Println("Check contract conf store RPC Endpoint endpoint URL:", event["endpointURL"])
}

// called before main()
func init() {
	var err error
	client, err = ethclient.Dial("http://localhost:8545")
	checkError(err)
	fr = framework.New()
}

var client *ethclient.Client
var path = "SealedAuction.sol/SealedAuction.json"
var fr *framework.Framework

func main() {
	// suave-geth --suave.dev --suave.eth.external-whitelist='*'
	// TODO: install go dependencies: create go.mod from example add replace line
	// forge build
	// copy SealedAuction.json to go/pkg (see example below)
	// sudo cp ./out/SealedAuction.sol/SealedAuction.json  /home/timm/go/pkg/mod/github.com/flashbots/suapp-examples@v0.0.0-20241031122241-896ca6742979/out/SealedAuction.sol/SealedAuction.json
	// go run main.go
	pause := true
	if pause {
		mainWithPause()
		return
	}
	/* 	auctionEndTime := big.NewInt(4)
	   	chainID := big.NewInt(22)
	   	nftName := "myNFT"
	   	var _ = deployContractWithConstructor(auctionEndTime, nftName, chainID) */
	/* 	mainWithPause()
	   	return */
	fmt.Println("1. Deploy Sealed Auction contract")
	//contract := deployContractWithConstructor()
	var contract = deployContract(path)

	fmt.Println("2. Register RPC endpoint")
	registerRPC(contract)
	printRPCEndpoint(contract)

	fmt.Println("3. Print Contract Info")
	printContractInfo(contract)

	fmt.Println("4. Print Chain Info")
	printChainInfoComplete()

	fmt.Println("5. Create new account & bid")
	num_accounts := 5
	bidders := make([]*framework.PrivKey, 0)
	for i := 0; i < num_accounts; i++ {
		bidders = append(bidders, createAccount())
		bidContract := contract.Ref(bidders[i])
		placeBid(bidders[i], bidContract)
	}

	fmt.Println("6. Print Contract Info again")
	printContractInfo(contract)

}

func mainWithPause() {
	var input = ""

	fmt.Println("1. Deploy Sealed Auction contract")
	var contract = deployContract(path)
	fmt.Scanln(&input)

	fmt.Println("2. Register RPC endpoint")
	registerRPC(contract)
	printRPCEndpoint(contract)
	fmt.Scanln(&input)

	fmt.Println("3. Print Contract Info")
	printContractInfo(contract)
	fmt.Scanln(&input)

	fmt.Println("4. Print Chain Info")
	printChainInfoComplete()
	fmt.Scanln(&input)

	fmt.Println("5. Create new account & bid")
	num_accounts := 5
	bidders := make([]*framework.PrivKey, 0)
	for i := 0; i < num_accounts; i++ {
		fmt.Scanln(&input)
		bidders = append(bidders, createAccount())
		bidContract := contract.Ref(bidders[i])
		fmt.Scanln(&input)
		fmt.Println("Bidder ", i+1, " places bid:")
		placeBid(bidders[i], bidContract)
	}
	fmt.Scanln(&input)

	fmt.Println("6. Print Contract Info again")
	printContractInfo(contract)

}

func checkError(err error) {
	if err != nil {
		panic(err)
	}
}
