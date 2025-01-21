package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io/ioutil"
	"log"
	"math/big"
	"net/http"
	"os"
	"strconv"
	"suave/whisperwins/framework"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/ethereum/go-ethereum/suave/sdk"
	"github.com/joho/godotenv"
)

var SuaveClient *ethclient.Client
var SuaveDevAccount *framework.PrivKey
var L1client *ethclient.Client

var path = "SealedAuction.sol/SealedAuction.json"
var fr *framework.Framework

func init() {
	var err error
	SuaveClient, err = ethclient.Dial("http://localhost:8545")
	checkError(err)
	fr = framework.New(framework.WithL1())
	err = godotenv.Load()
	checkErrorWithMessage(err, "Error loading .env file: ")

	privKeySuave := os.Getenv("SERVER_PRIVATE_KEY")
	if privKeySuave == "" {
		log.Fatal("ENTER PRIVATE Suave KEY in .env file!")
	}
	SuaveDevAccount = framework.NewPrivKeyFromHex(privKeySuave)
	L1client, err = ethclient.Dial("http://localhost:8555")
	checkError(err)
}

func main() {
	artifact, err := framework.ReadArtifact(path)
	if err != nil {
		panic(err)
	}

	if len(os.Args) > 1 {
		arg := os.Args[1]
		newClient := sdk.NewClient(SuaveClient.Client(), SuaveDevAccount.Priv, fr.KettleAddress)
		stdContract := sdk.GetContract(common.HexToAddress(arg), artifact.Abi, newClient)
		sdk.SetDefaultGasLimit(0)
		contractSuave := framework.CreateContract(common.HexToAddress(arg), newClient, fr.KettleAddress, artifact.Abi, stdContract)
		receipt := contractSuave.SendConfidentialRequest("revealBidders", nil, nil)
		if receipt.Status == types.ReceiptStatusFailed {
			panic("Revealing Bidders tx Failed")
		}
		maxBalance := big.NewInt(0)
		winnerL1 := common.HexToAddress("0x0")
		finalBlockNumber := getFieldFromContract(contractSuave, "finalBlockNumber")[0].(*big.Int).Uint64()
		for i := 0; i < len(receipt.Logs); i++ {
			event, err := contractSuave.Abi.Events["RevealBiddingAddress"].ParseLog(receipt.Logs[i])
			checkError(err)
			//balance, err := L1client.BalanceAt(context.Background(), event["bidderL1"].(common.Address), nil)
			balance := getBalanceAtBlock(event["bidderL1"].(common.Address), finalBlockNumber)
			checkError(err)
			if balance > maxBalance.Int64() {
				maxBalance = big.NewInt(balance)
				winnerL1 = event["bidderL1"].(common.Address)
			} else if balance == maxBalance.Int64() {
				//TODO: handle multiple same bids case
			}
		}
		// TODO: we can send the L1 address and compute the according SuaveAddress in the contract (now we send the suave address! CHANGE!)
		receipt = contractSuave.SendConfidentialRequest("registerWinner", []interface{}{winnerL1, maxBalance}, nil)
		if receipt.Status == types.ReceiptStatusFailed {
			log.Fatal("FAILED")
			return
		}
		//Print winner to stdout
		fmt.Print(getFieldFromContract(contractSuave, "auctionWinnerL1"))
	} else {
		log.Fatal("No arguments provided")
	}

}

func getFieldFromContract(contract *framework.Contract, fieldName string) []interface{} {
	res := contract.Call(fieldName, nil)
	return res
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

func getBalanceAtBlock(
	l1Address common.Address,
	finalETHBlock uint64) int64 {
	url := "http://127.0.0.1:8555/"
	chainID, err := L1client.ChainID(context.Background())
	checkError(err)
	payload := []byte(fmt.Sprintf(`{"jsonrpc":"2.0", "method": "eth_getProof", "params": ["%s", [], "0x%x"], "id": "%d"}`, l1Address, finalETHBlock, chainID.Int64()))
	// Make the POST request
	resp, err := http.Post(url, "application/json", bytes.NewBuffer(payload))
	checkError(err)
	defer resp.Body.Close()
	body, err := ioutil.ReadAll(resp.Body)
	checkError(err)
	var jsonResult map[string]interface{}

	err = json.Unmarshal([]byte(body), &jsonResult)
	if err != nil {
		log.Fatal(err)
	}

	result, ok := jsonResult["result"].(map[string]interface{})
	if !ok {
		log.Fatal("Key 'result' is not a valid map")
	}

	balance, ok := result["balance"].(string)
	if !ok {
		log.Fatal("Key 'balance' is not a string")
	}

	res, err := strconv.ParseInt(balance, 0, 64)
	return res
}
