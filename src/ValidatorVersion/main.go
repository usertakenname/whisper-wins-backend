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
	"strconv"
	"strings"

	"os"
	"time"

	"suave/whisperwins/framework"

	"github.com/ethereum/go-ethereum/accounts/abi"
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
	if strings.Contains(_path, "SealedAuction") {
		writeTextToFile("Deploying the auction contract: " + fmt.Sprintf("%d", receipt.GasUsed))
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
	receipt, err := contract.SendConfidentialRequest("getBiddingAddress", nil, randomKey)
	checkError(err)
	printReceipt(receipt, contract)
	event, err := contract.Abi.Events["EncBiddingAddress"].ParseLog(receipt.Logs[0])
	checkError(err)
	encryptedBiddingAddress := event["encryptedL1Address"].([]byte)
	plainTextAddress := decryptSecretAddress(randomKey, encryptedBiddingAddress)
	fmt.Println("Owner of Bidding address:", event["owner"])
	fmt.Println("Encrypted L1 bidding address:", hex.EncodeToString(encryptedBiddingAddress))
	fmt.Println("Decrypted L1 bidding address:", plainTextAddress)

	writeTextToFile("Getting a bidding address: " + fmt.Sprintf("%d", receipt.GasUsed))

	return plainTextAddress
}

func startAuction(contract *framework.Contract) {
	receipt, err := contract.SendConfidentialRequest("startAuction", nil, nil)
	if err != nil {
		fmt.Println("Starting the auction failed, will try again in 10 seconds")
		time.Sleep(10 * time.Second)
		receipt, err = contract.SendConfidentialRequest("startAuction", nil, nil)
		checkError(err)
	}
	checkError(err)
	for i := range receipt.Logs {
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
	writeTextToFile("Start auction: " + fmt.Sprintf("%d", receipt.GasUsed))
}

func endAuction(contract *framework.Contract) {
	receipt, err := contract.SendConfidentialRequest("endAuction", nil, nil)
	checkError(err)

	fmt.Println("Auction took gas: ", receipt.GasUsed)
	fmt.Println("Effective gas price: ", receipt.EffectiveGasPrice)
	fmt.Println("Cumulative gas used: ", receipt.CumulativeGasUsed)
	printReceipt(receipt, contract)
	for i := range receipt.Logs {
		if receipt.Logs[i].Topics[0] == oracle.Abi.Events["TxEvent"].ID {
			event, err := oracle.Abi.Events["TxEvent"].ParseLog(receipt.Logs[i])
			checkError(err)
			txHash := event["txHash"].(string)
			tx, _, err := L1client.TransactionByHash(context.Background(), common.HexToHash(txHash))
			checkError(err)
			waitForTxToBeIncluded(tx)
			L1receipt, err := L1client.TransactionReceipt(context.Background(), common.HexToHash(txHash))
			checkError(err)
			writeTextToFile("End auction transfer tax on L1: " + fmt.Sprintf("%d", L1receipt.GasUsed))
		}
	}
	writeTextToFile("Ending auction on SUAVE: " + fmt.Sprintf("%d", receipt.GasUsed))
}

var SuaveClient *ethclient.Client
var L1client *ethclient.Client
var L1chainID *big.Int
var L1DevAccount *framework.PrivKey
var SuaveDevAccount *framework.PrivKey
var writeToFile bool
var path = "SealedAuctionValidator.sol/SealedAuctionValidator.json"
var fr *framework.Framework
var oracle *framework.Contract

func setUpAuction(contract *framework.Contract) {
	receipt, err := contract.SendConfidentialRequest("setUpAuction", nil, nil)
	checkError(err)
	printReceipt(receipt, contract)
	writeTextToFile("Setup: " + fmt.Sprintf("%d", receipt.GasUsed))
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
		} else if receipt.Logs[i].Topics[0] == contract.Abi.Events["TestEvent"].ID { // TODO DELETE
			event, err := contract.Abi.Events["TestEvent"].ParseLog(receipt.Logs[i])
			checkError(err)
			fmt.Println("NFTHoldingAddrTestEventessEvent : ", event["test"])
		} else if receipt.Logs[i].Topics[0] == oracle.Abi.Events["ErrorEvent"].ID {
			event, err := oracle.Abi.Events["ErrorEvent"].ParseLog(receipt.Logs[i])
			checkError(err)
			fmt.Println("ErrorEvent : ", event["errorMsg"])
		} else if receipt.Logs[i].Topics[0] == oracle.Abi.Events["TxEvent"].ID {
			event, err := oracle.Abi.Events["TxEvent"].ParseLog(receipt.Logs[i])
			checkError(err)
			fmt.Println("TxEvent : ", event["txHash"])
		} else if receipt.Logs[i].Topics[0] == oracle.Abi.Events["EncodedTx"].ID {
			event, err := oracle.Abi.Events["EncodedTx"].ParseLog(receipt.Logs[i])
			checkError(err)
			fmt.Println("signedTx : ", event["signedTx"])
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
	keyBytes := make([]byte, 32)
	copy(keyBytes[:], key[:])

	c, err := aes.NewCipher(keyBytes)
	if err != nil {
		return nil, fmt.Errorf("failed to create AES cipher: %w", err)
	}

	gcm, err := cipher.NewGCM(c)
	if err != nil {
		return nil, fmt.Errorf("failed to create GCM: %w", err)
	}

	nonceSize := gcm.NonceSize()
	if len(ciphertext) < nonceSize {
		return nil, fmt.Errorf("ciphertext too short")
	}

	nonce, ciphertext := ciphertext[:nonceSize], ciphertext[nonceSize:]

	plaintext, err := gcm.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to decrypt ciphertext: %w", err)
	}

	return plaintext, nil
}

// Used for winner, losers & Auction Owner
func claim(contract *framework.Contract) {
	//toAdd := L1DevAccount.Address().Hex()
	receipt, err := contract.SendConfidentialRequest("claim", []interface{}{L1DevAccount.Address().Hex()}, nil)

	if err != nil {
		log.Println("Claim failed; continue like it worked")
		log.Println(err)
	} else if receipt.Status == types.ReceiptStatusFailed {
		log.Println("Claim failed STATUS Incorrect; continue like it worked")
		log.Println(err)
		log.Println(receipt)
	} else {
		printReceipt(receipt, contract)
		for i := range receipt.Logs {
			if receipt.Logs[i].Topics[0] == oracle.Abi.Events["EncodedTx"].ID {
				event, err := oracle.Abi.Events["EncodedTx"].ParseLog(receipt.Logs[i])
				checkError(err)
				signedTx := event["signedTx"].(string)
				sendSignedTx(signedTx)
			}
		}
		writeTextToFile("Claiming valuables on SUAVE: " + fmt.Sprintf("%d", receipt.GasUsed))
	}

}

func deployOracle() *framework.Contract {
	chainID := big.NewInt(SEPOLIA_CHAIN_ID)
	oracle = deployContractWithConstructor("OracleValidator.sol/OracleValidator.json", SuaveDevAccount, chainID)
	api_key := os.Getenv("ALCHEMY_API_KEY")
	if api_key == "" {
		log.Fatal("ENTER ALCHEMY_API_KEY in .env file!")
	}
	api_key2 := os.Getenv("ETHERSCAN_API_KEY")
	if api_key == "" {
		log.Fatal("ENTER ETHERSCAN_API_KEY in .env file!")
	}
	fmt.Println("Oracle contract owner:", oracle.Call("owner", nil)[0])
	fmt.Println("Current sender:", SuaveDevAccount.Address())
	receipt, err := oracle.SendConfidentialRequest("registerApiKeyOffchain", []interface{}{"alchemy"}, []byte(api_key))
	checkError(err)
	if receipt.Status == types.ReceiptStatusSuccessful {
		fmt.Println("ALCHEMY_API Key registered")
	}
	receipt, err = oracle.SendConfidentialRequest("registerApiKeyOffchain", []interface{}{"etherscan"}, []byte(api_key2))
	checkError(err)
	if receipt.Status == types.ReceiptStatusSuccessful {
		fmt.Println("ETHERSCAN_API Key registered")
	}
	return oracle
}

func init() { // DEPRECATED: for toliman suave chain dial https://rpc.toliman.suave.flashbots.net
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
	privKey := os.Getenv("L1_PRIVATE_KEY")
	if privKey == "" {
		log.Fatal("ENTER PRIVATE L1 KEY in .env file!")
	}
	L1DevAccount = framework.NewPrivKeyFromHex(privKey)
	SuaveDevAccount = framework.NewPrivKeyFromHex(privKeySuave)
	L1client, err = ethclient.Dial("https://sepolia.infura.io/v3/93302e94e89f41afafa250f8dce33086") //TODO CHANGE TO ENV
	checkError(err)
	L1chainID = big.NewInt(SEPOLIA_CHAIN_ID)
	writeToFile = true
}

// with already existing contract
func claimProcedure(bidder *framework.PrivKey) {
	gasPrice, err := SuaveClient.SuggestGasPrice(context.Background())
	checkError(err)
	nftAddressString := os.Getenv("NFT_CONTRACT_ADDRESS")
	if nftAddressString == "" {
		log.Fatal("ENTER NFT_CONTRACT_ADDRESS in .env file!")
	}
	tokenIDString := os.Getenv("NFT_TOKEN_ID")
	if tokenIDString == "" {
		log.Fatal("ENTER NFT_TOKEN_ID in .env file!")
	}
	tokenIDUint, err := strconv.ParseUint(tokenIDString, 10, 64)
	checkError(err)
	nftTokenID := new(big.Int).SetUint64(tokenIDUint)
	nftContractAddress := common.HexToAddress(nftAddressString)
	nftHoldingAddress := bidder.Address()
	makeTransaction(L1DevAccount, big.NewInt(gasPrice.Int64()*80000*4), nftHoldingAddress)
	fmt.Println("returning the NFT to main account")
	moveNft(L1DevAccount.Address(), nftTokenID, nftContractAddress, bidder)

	fmt.Println("returning the funds left on NFT holding address to main account")
	sendAllBalance(bidder, L1DevAccount.Address())
}

func sendSignedTx(signedTxHex string) {
	txBytes, err := hex.DecodeString(strings.TrimPrefix(signedTxHex, "0x"))
	checkError(err)
	tx := new(types.Transaction)
	err = tx.UnmarshalBinary(txBytes)
	checkError(err)
	err = L1client.SendTransaction(context.Background(), tx)
	checkError(err)
	fmt.Println("Signed transaction sent! Hash:", tx.Hash().Hex())
	waitForTxToBeIncluded(tx)
	L1receipt, err := L1client.TransactionReceipt(context.Background(), tx.Hash())
	checkError(err)
	writeTextToFile("Claiming valuables on L1: " + fmt.Sprintf("%d", L1receipt.GasUsed))
}

func main() {
	//args := os.Args
	if true {
		//num_bidder, err := strconv.Atoi(args[1])
		//checkError(err)
		num_biddder := 4
		writeTextToFile("\nStarting the rollup auction with bidder amount: " + fmt.Sprintf("%d", num_biddder))
		procedure(num_biddder)
	} else {
		claimProcedure(framework.NewPrivKeyFromHex("099046940d267eca6761bafe645c17733f3b2eaf952ee7c866b601abb07ea0ac"))
	}
}

func procedure(num_bidder int) {
	gasPrice, err := SuaveClient.SuggestGasPrice(context.Background())
	checkError(err)
	fmt.Println("Current Suave Toliman Gas Price: ", gasPrice)

	fmt.Println("0. Preparation: Deploy oracle on TOLIMAN SUAVE CHAIN")
	oracleAddress := deployOracle().Raw().Address()

	fmt.Println("1. Deploy Sealed Auction contract on TOLIMAN SUAVE CHAIN")
	auctionInSeconds := int64(num_bidder * 50)
	auctionEndTime := big.NewInt(int64(time.Now().Unix() + auctionInSeconds))
	refuteTime := big.NewInt(30)
	nftTokenID, minimalBiddingAmount := big.NewInt(3), big.NewInt(1000000000)               // 1 GWEI
	nftContractAddress := common.HexToAddress("0x752dDaf94E17df2827F2140998df02Bfd998F1FB") //TODO REPLACE WITH ENV
	contract := deployContractWithConstructor(path, SuaveDevAccount, nftContractAddress, nftTokenID, auctionEndTime, minimalBiddingAmount, oracleAddress, refuteTime)

	fmt.Println("2 Setup Auction")
	setUpAuction(contract)
	nftHoldingAddress := getFieldFromContract(contract, "nftHoldingAddress")[0].(common.Address)
	fundL1Account(nftHoldingAddress, big.NewInt(1000000000000000))
	getPrivKey(contract)

	fmt.Println("3. Moving the NFT from auctioneer to holding address")
	moveNft(nftHoldingAddress, nftTokenID, nftContractAddress, L1DevAccount)

	fmt.Println("4. Start Auction")
	startAuction(contract)
	/* 	_, err = contract.SendConfidentialRequest("startAuctionTest", nil, nil) // TODO change to actual start auction
	   	checkError(err) */
	num_accounts := num_bidder
	fmt.Println("5. Place bid with ", num_accounts, " accounts")
	bidders := make([]*framework.PrivKey, 0)

	for i := range num_accounts {
		fmt.Println("Creating account #", i)
		bidders = append(bidders, createAccount())
		fmt.Println("Private key of bidder: ", hex.EncodeToString(bidders[i].Priv.D.Bytes()))
		bidContract := contract.Ref(bidders[i])
		placeBid(bidders[i], bidContract)
	}
	fmt.Println("Waiting ", auctionInSeconds, " seconds for the auction to be over.")
	time.Sleep(time.Duration(auctionInSeconds) * time.Second)

	fmt.Println("6. End Auction")
	endAuction(contract)
	getFieldFromContract(contract, "auctionWinnerL1")
	getFieldFromContract(contract, "auctionWinnerSuave")
	getFieldFromContract(contract, "winningBid")
	for i := range num_accounts {
		res := contract.Call("revealedL1Addresses", []interface{}{big.NewInt(int64(i))})
		fmt.Println("bidder ", i, " ", res[0])
		receipt, err := contract.SendConfidentialRequest("refuteWinner", []any{res[0]}, nil)
		if err != nil {
			fmt.Println("Trying again")
			receipt, err = contract.SendConfidentialRequest("refuteWinner", []any{res[0]}, nil)
		}
		checkError(err)
		writeTextToFile("Registering new winner: " + fmt.Sprintf("%d", receipt.GasUsed))
		printReceipt(receipt, contract)
		getFieldFromContract(contract, "auctionWinnerL1")
		getFieldFromContract(contract, "auctionWinnerSuave")
		getFieldFromContract(contract, "winningBid")
	}
	/* 	fmt.Println("Waiting ", refuteTime, " seconds for the refute time to be over.")
	   	time.Sleep(time.Duration(refuteTime.Int64()) * time.Second) */
	fmt.Println("7b. Claim: Get winning bid as auctioneer")
	claim(contract)

	fmt.Println("7a. Claim: get NFT for winner & return bids")
	for i := range num_bidder {
		bidContract := contract.Ref(bidders[i])
		claim(bidContract)
	}
}

func moveNft(toAddress common.Address, nftTokenID *big.Int, nftContractAddress common.Address, privKeySender *framework.PrivKey) {
	const erc721ABI = `[{"inputs":[{"internalType":"address","name":"from","type":"address"},{"internalType":"address","name":"to","type":"address"},{"internalType":"uint256","name":"tokenId","type":"uint256"}],"name":"safeTransferFrom","outputs":[],"stateMutability":"payable","type":"function"}]`

	contractABI, err := abi.JSON(strings.NewReader(erc721ABI))
	checkError(err)
	transactor, err := bind.NewKeyedTransactorWithChainID(privKeySender.Priv, big.NewInt(SEPOLIA_CHAIN_ID))
	checkError(err)
	nonce, err := L1client.PendingNonceAt(context.Background(), privKeySender.Address())
	fmt.Println("Nonce of auctioneer: ", privKeySender.Address(), "   :", nonce)
	checkError(err)
	gasPrice, err := L1client.SuggestGasPrice(context.Background())
	checkError(err)
	fmt.Println("Current gas price: ", gasPrice)
	transactor.Nonce = big.NewInt(int64(nonce))
	transactor.Value = big.NewInt(0)
	transactor.GasLimit = uint64(200000)
	transactor.GasPrice = new(big.Int).Mul(big.NewInt(4), gasPrice)

	data, err := contractABI.Pack("safeTransferFrom", privKeySender.Address(), toAddress, nftTokenID)
	checkError(err)

	tx := types.NewTransaction(nonce, nftContractAddress, big.NewInt(0), transactor.GasLimit, gasPrice, data)

	signedTx, err := types.SignTx(tx, types.NewEIP155Signer(big.NewInt(SEPOLIA_CHAIN_ID)), privKeySender.Priv)
	checkError(err)
	err = L1client.SendTransaction(context.Background(), signedTx)
	checkError(err)

	log.Printf("Transaction sent! Hash: %s\n", signedTx.Hash().Hex())
	waitForTxToBeIncluded(signedTx)
	receipt, err := L1client.TransactionReceipt(context.Background(), signedTx.Hash())
	checkError(err)
	if receipt.Status == types.ReceiptStatusFailed {
		panic("Moving the NFT Failed")
	}
	writeTextToFile("L1 Moving the NFT to NFT holding address: " + fmt.Sprintf("%d", receipt.GasUsed))
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
	log.Printf("funder %s with balance: %s", funderAddr.Hex(), balance.String())
	value.Add(value, header.BaseFee)         // add baseFee from last block
	value.Add(value, big.NewInt(1000000000)) // plus one GWEI for priority
	gasPrice.Mul(gasPrice, big.NewInt(21000))
	value.Add(value, gasPrice) // add gascosts
	log.Printf("funding account %s with %s .", to.Hex(), value.String())
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

// make L1 Transaction
// @params: privKey of sender; value of ETH transfer, to Address of receiver
func makeTransaction(privKey *framework.PrivKey, value *big.Int, to common.Address) {
	gasPrice, err := L1client.SuggestGasPrice(context.Background())
	checkError(err)
	nonce, err := L1client.PendingNonceAt(context.Background(), privKey.Address())
	checkError(err)
	tip := big.NewInt(1500000000) // 1,5 Gwei
	currentNonce, err := L1client.NonceAt(context.Background(), privKey.Address(), nil)
	checkError(err)
	gasFee := big.NewInt(50000000).Add(gasPrice, tip)
	fmt.Printf("GasPrice %d\t gasFeeCap %e\n", gasPrice, gasFee)
	if nonce != currentNonce {
		fmt.Printf("Current nonce: %d and using nonce: %d\n", currentNonce, nonce)
		nonce = currentNonce // override slow transaction (only use when tx is stuck)
	}
	txnLegacy := &types.DynamicFeeTx{
		Nonce:      nonce,
		Value:      value,
		To:         &to,
		Data:       nil,
		Gas:        21000,
		ChainID:    L1chainID,
		GasTipCap:  tip,
		GasFeeCap:  gasFee,
		AccessList: nil,
	}
	tx := types.NewTx(txnLegacy)
	signer := types.LatestSignerForChainID(L1chainID)
	signedTx, err := types.SignTx(tx, signer, privKey.Priv)
	checkError(err)
	err = L1client.SendTransaction(context.Background(), signedTx)
	checkError(err)
	waitForTxToBeIncluded(signedTx)
}

func waitForTxToBeIncluded(signedTx *types.Transaction) {
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
	_, err := bind.WaitMined(context.Background(), L1client, signedTx)
	checkErrorWithMessage(err, "Error waiting for transaction to be mined: ")
}

func createAccount() *framework.PrivKey {
	newAccountPrivKey := framework.GeneratePrivKey()
	log.Printf("Created Address at: %s", newAccountPrivKey.Address().Hex())
	fundBalance := big.NewInt(500000000000000) // fund 500.000 GWEI on L1
	fmt.Println("Funding the L1 account with balance: ", fundBalance)
	err := fundL1Account(newAccountPrivKey.Address(), fundBalance)
	checkError(err)
	fundBalance = big.NewInt(200000000000000000) // 0,2 ETH on SUAVE
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

func placeBid(privKey *framework.PrivKey, bidContract *framework.Contract) {
	toAddress := common.HexToAddress(getBiddingAddress(bidContract))
	//amount := big.NewInt(15000000000000 + int64(rand.Intn(2000))) // (15.000 GWEI + ~2000)
	// L1: create tx to send money
	//fmt.Println("Place bid with amount ", amount, " to adddress ", toAddress)
	sendAllBalance(privKey, toAddress)
	//makeTransaction(privKey, amount, toAddress)
	//fmt.Println(privKey.Address(), " bid ", amount, " to ", toAddress)
}

// TODO DELETE
func getPrivKey(contract *framework.Contract) string {
	receipt, err := contract.SendConfidentialRequest("getPrivKey", nil, nil)
	checkError(err)
	for i := 0; i < len(receipt.Logs); i++ {
		if receipt.Logs[i].Topics[0] == contract.Abi.Events["TestEvent"].ID {
			event, err := contract.Abi.Events["TestEvent"].ParseLog(receipt.Logs[i])
			checkError(err)
			fmt.Println("Revealed Private key:", event["test"])
			return event["test"].(string)
		}
	}
	return ""
}

func sendAllBalance(privKey *framework.PrivKey, to common.Address) {
	from := privKey.Address()
	balance, err := L1client.BalanceAt(context.Background(), from, nil)
	checkError(err)
	gasPrice, err := L1client.SuggestGasPrice(context.Background())
	checkError(err)
	tip := big.NewInt(1500000000) // 1.5 Gwei
	gasFee := big.NewInt(0).Add(gasPrice, tip)
	gasLimit := uint64(21000)
	totalGasCost := big.NewInt(0).Mul(gasFee, big.NewInt(int64(gasLimit)))

	if balance.Cmp(totalGasCost) <= 0 {
		fmt.Printf("Insufficient balance to cover gas: balance=%s, gasCost=%s. Skipping this transaction", balance, totalGasCost)
		return
	}

	valueToSend := big.NewInt(0).Sub(balance, totalGasCost)
	nonce, err := L1client.PendingNonceAt(context.Background(), from)
	checkError(err)
	currentNonce, err := L1client.NonceAt(context.Background(), from, nil)
	checkError(err)
	if nonce != currentNonce {
		fmt.Printf("Current nonce: %d and using nonce: %d\n", currentNonce, nonce)
		nonce = currentNonce // override slow transaction (only use when tx is stuck)
	}

	txn := &types.DynamicFeeTx{
		Nonce:      nonce,
		Value:      valueToSend,
		To:         &to,
		Data:       nil,
		Gas:        gasLimit,
		ChainID:    L1chainID,
		GasTipCap:  tip,
		GasFeeCap:  gasFee,
		AccessList: nil,
	}
	tx := types.NewTx(txn)
	signer := types.LatestSignerForChainID(L1chainID)
	signedTx, err := types.SignTx(tx, signer, privKey.Priv)
	checkError(err)
	err = L1client.SendTransaction(context.Background(), signedTx)
	checkError(err)
	waitForTxToBeIncluded(signedTx)
	fmt.Printf("Sent %s wei from %s to %s (all balance minus gas)\n", valueToSend.String(), from.Hex(), to.Hex())
}

func writeTextToFile(text string) {
	if writeToFile {
		file, err := os.OpenFile("measurements.txt", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
		checkError(err)
		_, err = file.WriteString(text + "\n")
		checkError(err)
	}
}
