package main

import (
	"context"
	"fmt"
	"log"
	"math/big"
	"os"
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

	privKeySuave := os.Getenv("SUAVE_DEV_PRIVATE_KEY")
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
		winner := common.HexToAddress("0x0")

		for i := 0; i < len(receipt.Logs); i++ {
			event, err := contractSuave.Abi.Events["RevealBiddingAddress"].ParseLog(receipt.Logs[i])
			checkError(err)
			balance, err := L1client.BalanceAt(context.Background(), event["bidderL1"].(common.Address), nil)
			checkError(err)
			if balance.CmpAbs(maxBalance) == 1 {
				maxBalance = balance
				winner = event["bidderSuave"].(common.Address)
			} else if balance.CmpAbs(maxBalance) == 0 {
				//TODO: handle multiple same bids case
			}
		}
		receipt = contractSuave.SendConfidentialRequest("registerWinner", []interface{}{winner, maxBalance}, nil)
		if receipt.Status == types.ReceiptStatusFailed {
			log.Fatal("FAILED")
			return
		}
		//Print winner to stdout
		fmt.Print(getFieldFromContract(contractSuave, "auctionWinner"))
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
