package main

import (
	"context"
	"fmt"
	"io/ioutil"
	"log"
	"math/big"
	"os"

	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/accounts/keystore"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/ethereum/go-ethereum/suave/sdk"
	"github.com/flashbots/suapp-examples/framework"
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
func deployContractWithConstructor() *bind.BoundContract {
	artifact, err := framework.ReadArtifact(path)
	if err != nil {
		panic(err)
	}
	privKey, err := crypto.HexToECDSA("91ab9a7e53c220e6210460b65a7a3bb2ca181412a8a7b43ff336b3df1737ce12")
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println("Here")
	num3 := big.NewInt(16813125)
	auth, err := bind.NewKeyedTransactorWithChainID(privKey, num3) // Chain ID for suave testnet
	if err != nil {
		log.Fatalf("Failed to create authorized transactor: %v", err)
	}
	num1 := big.NewInt(10)
	num2 := big.NewInt(22)
	str1 := "myNFT"
	fmt.Println(artifact.Abi)
	_, tx, contract, err := bind.DeployContract(auth, *artifact.Abi, artifact.Code, client, num1, str1, num2)
	if err != nil {
		log.Fatalf("Error waiting for : %v", err)
	}
	fmt.Println("Waiting for contract deployment transaction to be included...")
	receipt, err := bind.WaitMined(context.Background(), client, tx)
	if err != nil {
		log.Fatalf("Error waiting for contract deployment transaction to be included: %v", err)
	}
	fmt.Println(receipt)
	return contract
}

// only prints latest emitted event; flag to request new  event
func printInfo(contract *framework.Contract) {
	receipt := contract.SendConfidentialRequest("printInfo", nil, nil)
	event, err := contract.Abi.Events["AuctionOpened"].ParseLog(receipt.Logs[0])
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println("Contract address:", event["contractAddr"])
	fmt.Println("End Timestamp: ", event["endTimestamp"])
	fmt.Println("Number of Bidders: ", event["bidderAmount"])
}

func registerRPC(contract *framework.Contract) {
	confidentialInput := "https://sepolia.infura.io/v3/93302e94e89f41afafa250f8dce33086"
	chainID := big.NewInt(11155111)
	receipt := contract.SendConfidentialRequest("registerRPCOffchain", []interface{}{chainID}, []byte(confidentialInput))
	event, err := contract.Abi.Events["RPCEndpointUpdated"].ParseLog(receipt.Logs[0])
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println("RPC Point updated to chainID:", event["chainId"])
}

func getBiddingAddress(contract *framework.Contract) {
	receipt := contract.SendConfidentialRequest("getBiddingAddress", nil, nil)
	event, err := contract.Abi.Events["BiddingAddress"].ParseLog(receipt.Logs[0])
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println("Owner of Bidding address:", event["owner"])
	fmt.Println("Encoded L1 address:", event["encodedL1Address"])
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
			fmt.Println("Balance of account: ", privKey.Address(), ":\t", bal)
		}
	}
}

// TODO: adapt to something useful
func makeTransaction(privKey *framework.PrivKey) {
	newClient := sdk.NewClient(client.Client(), privKey.Priv, fr.KettleAddress)
	gas := big.NewInt(10000)
	txn := &types.LegacyTx{
		Nonce:    1,
		To:       &fr.KettleAddress,
		Value:    gas,
		Gas:      10000000,
		GasPrice: gas,
		Data:     nil,
	}
	res, err := newClient.SendTransaction(txn)
	if err != nil {
		log.Fatal(err)
	}
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
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(mes, out)
}

// called before main()
func init() {
	var err error
	client, err = ethclient.Dial("http://localhost:8545")
	if err != nil {
		panic(err)
	}
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

	//createKs()
	//importKs()
	fmt.Println("1. Deploy Sealed Auction contract")
	/* 	var _ = deployContractWithConstructor()*/
	var contract = deployContract(path)
	fmt.Println("2. Print Info")
	printInfo(contract)
	fmt.Println("3. Register RPC endpoint")
	registerRPC(contract)
	fmt.Println("4. Get Bidding address for sender")
	getBiddingAddress(contract)
	//TODO: place Bid
	printChainInfoComplete()

	testAccPrivKey := createAccount()
	fmt.Println("TODO: do something with priv key:", *testAccPrivKey.Priv)
	makeTransaction(testAccPrivKey)
}
