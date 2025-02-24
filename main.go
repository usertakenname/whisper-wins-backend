package main

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	cryptorand "crypto/rand"
	"encoding/hex"
	"fmt"
	"log"
	"math/big"

	"os"
	"time"

	"suave/whisperwins/framework"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/ethereum/go-ethereum/suave/sdk"
	"github.com/joho/godotenv"
)

const (
	SEPOLIA_CHAIN_ID           = 11155111
	SUAVE_TESTNET_CHAIN_ID     = 16813125
	LOCAL_TESTCHAIN_ID         = 1234321
	TOLIMAN_SUAVE_TESTCHAIN_ID = 33626250
)

func deployContractWithConstructor(_path string, SuaveDevAccount *framework.PrivKey, params ...interface{}) *framework.Contract {
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

func getBiddingAddress(contract *framework.Contract) string {
	randomKey, err := GenerateRandomKey()
	checkError(err)
	receipt := contract.SendConfidentialRequest("getBiddingAddress", nil, randomKey)
	event, err := contract.Abi.Events["EncBiddingAddress"].ParseLog(receipt.Logs[0])
	checkError(err)
	encryptedBiddingAddress := event["encryptedL1Address"].([]byte)
	plainTextAddress := decryptSecretAddress(randomKey, encryptedBiddingAddress)
	fmt.Println("Owner of Bidding address:", event["owner"])
	fmt.Println("Encrypted L1 bidding address:", hex.EncodeToString(encryptedBiddingAddress))
	fmt.Println("Decrypted L1 bidding address:", plainTextAddress)
	return plainTextAddress
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

func endAuction(contract *framework.Contract) {
	receipt := contract.SendConfidentialRequest("endAuction", nil, nil)
	if receipt.Status == types.ReceiptStatusFailed {
		log.Fatal("End Auction call failed")
	} else {
		fmt.Println("End auction results:")
	}
	fmt.Println("Auction took gas: ", receipt.GasUsed)
	fmt.Println("Effective gas price: ", receipt.EffectiveGasPrice)
	fmt.Println("Cumulative gas used: ", receipt.CumulativeGasUsed)
	printReceipt(receipt, contract)
}

var SuaveClient *ethclient.Client
var L1client *ethclient.Client
var L1chainID *big.Int
var L1DevAccount *framework.PrivKey
var SuaveDevAccount *framework.PrivKey

var path = "SealedAuction.sol/SealedAuction.json"
var fr *framework.Framework

func setUpAuction(contract *framework.Contract) {
	receipt := contract.SendConfidentialRequest("setUpAuction", nil, nil)
	printReceipt(receipt, contract)
}

func printReceipt(receipt *types.Receipt, contract *framework.Contract) {
	for i := 0; i < len(receipt.Logs); i++ {
		if receipt.Logs[i].Topics[0] == contract.Abi.Events["RevealBiddingAddresses"].ID {
			event, err := contract.Abi.Events["RevealBiddingAddresses"].ParseLog(receipt.Logs[i])
			checkError(err)
			fmt.Println("Revealed L1 addresses:", event["bidderL1"])
		} else if receipt.Logs[i].Topics[0] == contract.Abi.Events["WinnerAddress"].ID {
			event, err := contract.Abi.Events["WinnerAddress"].ParseLog(receipt.Logs[i])
			checkError(err)
			fmt.Println("winner:", event["winner"])
		} else if receipt.Logs[i].Topics[0] == contract.Abi.Events["NFTHoldingAddressEvent"].ID {
			event, err := contract.Abi.Events["NFTHoldingAddressEvent"].ParseLog(receipt.Logs[i])
			checkError(err)
			fmt.Println("NFTHoldingAddressEvent : ", event["nftHoldingAddress"])
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

func GenerateRandomKey() ([]byte, error) {
	key := make([]byte, 32)
	_, err := cryptorand.Read(key)
	if err != nil {
		return nil, err
	}
	return key, nil
}

func decryptSecretAddress(randomKey []byte, input []byte) string {
	plaintex, err := aesDecrypt(randomKey, input)
	checkError(err)
	return "0x" + hex.EncodeToString(plaintex)
}

func aesDecrypt(key []byte, ciphertext []byte) ([]byte, error) {
	// Ensure the key is 32 bytes (for AES-256)
	keyBytes := make([]byte, 32)
	copy(keyBytes[:], key[:])

	// Create a new AES cipher with the key
	c, err := aes.NewCipher(keyBytes)
	if err != nil {
		return nil, fmt.Errorf("failed to create AES cipher: %w", err)
	}

	// Initialize GCM (Galois/Counter Mode)
	gcm, err := cipher.NewGCM(c)
	if err != nil {
		return nil, fmt.Errorf("failed to create GCM: %w", err)
	}

	// Check that the ciphertext is long enough
	nonceSize := gcm.NonceSize()
	if len(ciphertext) < nonceSize {
		return nil, fmt.Errorf("ciphertext too short")
	}

	// Extract the nonce and the actual ciphertext
	nonce, ciphertext := ciphertext[:nonceSize], ciphertext[nonceSize:]

	// Decrypt the ciphertext
	plaintext, err := gcm.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to decrypt ciphertext: %w", err)
	}

	return plaintext, nil
}

// Used for winner, losers & Auction Owner
func claim(contract *framework.Contract) {
	receipt := contract.SendConfidentialRequest("claim", []interface{}{SuaveDevAccount.Address()}, nil)
	if receipt.Status == types.ReceiptStatusFailed {
		log.Fatal("Claim failed")
	}
	printReceipt(receipt, contract)
}

func deployOracle() *framework.Contract {
	chainID := big.NewInt(SEPOLIA_CHAIN_ID)
	oracle := deployContractWithConstructor("Oracle.sol/Oracle.json", SuaveDevAccount, chainID)
	api_key := os.Getenv("ALCHEMY_API_KEY")
	if api_key == "" {
		log.Fatal("ENTER ALCHEMY_API_KEY in .env file!")
	}
	api_key2 := os.Getenv("ETHERSCAN_API_KEY")
	if api_key == "" {
		log.Fatal("ENTER ETHERSCAN_API_KEY in .env file!")
	}
	receipt := oracle.SendConfidentialRequest("registerApiKeyOffchain", []interface{}{"alchemy"}, []byte(api_key))
	if receipt.Status == types.ReceiptStatusSuccessful {
		fmt.Println("ALCHEMY_API Key registered")
	}
	receipt = oracle.SendConfidentialRequest("registerApiKeyOffchain", []interface{}{"etherscan"}, []byte(api_key2))
	if receipt.Status == types.ReceiptStatusSuccessful {
		fmt.Println("ETHERSCAN_API Key registered")
	}
	return oracle
}

func init() { // FOR TOLIMAN SUAVE CHAIN
	var err error
	SuaveClient, err = ethclient.Dial("https://rpc.toliman.suave.flashbots.net")
	checkError(err)
	fr = framework.New(framework.WithL1())
	err = godotenv.Load()
	checkErrorWithMessage(err, "Error loading .env file: ")
	privKeySuave := os.Getenv("SUAVE_DEV_PRIVATE_KEY")
	if privKeySuave == "" {
		log.Fatal("ENTER PRIVATE Suave KEY in .env file!")
	}
	privKey := os.Getenv("L1_PRIVATE_KEY")
	if privKey == "" {
		log.Fatal("ENTER PRIVATE L1 KEY in .env file!")
	}
	L1DevAccount = framework.NewPrivKeyFromHex(privKey)
	SuaveDevAccount = framework.NewPrivKeyFromHex(privKeySuave)
	L1client, err = ethclient.Dial("https://sepolia.infura.io/v3/93302e94e89f41afafa250f8dce33086")
	checkError(err)
	L1chainID = big.NewInt(SEPOLIA_CHAIN_ID)
}

func main() {

	gasPrice, err := SuaveClient.SuggestGasPrice(context.Background())
	checkError(err)
	fmt.Println("Current Suave Toliman Gas Price: ", gasPrice)
	//deployOracle().Raw().Address() // To Deploy your own oracle; also has to be changed in SealedAuction.sol

	fmt.Println("1. Deploy Sealed Auction contract on TOLIMAN SUAVE CHAIN")
	auctionInSeconds := int64(20)
	auctionEndTime := big.NewInt(int64(time.Now().Unix() + auctionInSeconds))
	nftTokenID, minimalBiddingAmount := big.NewInt(1), big.NewInt(1000000000)
	nftContractAddress := common.HexToAddress("0x166170D5246e697Bc3579003b85ce32d36831669")
	contract := deployContractWithConstructor(path, SuaveDevAccount, nftContractAddress, nftTokenID, auctionEndTime, minimalBiddingAmount)

	fmt.Println("2 Setup Auction")
	setUpAuction(contract)
	getFieldFromContract(contract, "nftHoldingAddress")
	// Step 2.5 Move NFT To NFTHoldingAddress Manually

	// The following is only a reference for implementation as the start auction requires the NFT to be moved
	/*
		fmt.Println("3. Start Auction")
		startAuction(contract)

		fmt.Println("6. getBiddingAddress")
		privKeyBidder := os.Getenv("SUAVE_BIDDER_PRIVATE_KEY")
		if privKeyBidder == "" {
			log.Fatal("ENTER SUAVE_BIDDER_PRIVATE_KEY in .env file!")
		}
		num_accounts := 1
		fmt.Println("6.1. Place bid with account ", num_accounts, " accounts")
		bidders := make([]*framework.PrivKey, 0)
		sdk.SetDefaultGasLimit(1000000)
		for i := 0; i < num_accounts; i++ {
			fmt.Println("Creating account #", i)
			bidders = append(bidders, framework.GeneratePrivKey())
			err := fr.Suave.FundAccount(bidders[i].Address(), big.NewInt(10000000000000000))
			checkError(err)
			bidContract := contract.Ref(bidders[i])
			getBiddingAddress(bidContract)
		}

		sdk.SetDefaultGasLimit(0)
		fmt.Println("7. End Auction")
		fmt.Println("Waiting ", auctionInSeconds, " seconds for the auction to be over.")
		time.Sleep(time.Duration(auctionInSeconds) * time.Second)

		endAuction(contract)

		// Wait until winning bid tax funds NFT Holding Address
		time.Sleep(15 * time.Second)
		fmt.Println("8. Get winning bid as auctioneer")
		claim(contract)

		fmt.Println("9 get NFT for winner")
		claim(contract.Ref(bidders[0]))
	*/
}
