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
	"math/rand"

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
		fmt.Println("Auction Winner L1:", event["auctionWinnerL1"])
		fmt.Println("Auction Winner Suave:", event["auctionWinnerSuave"])
		fmt.Println("Winning Bid:", event["winningBid"])
		fmt.Println("Revealed addresses:", event["revealedL1Addresses"])

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
	randomKey, err := GenerateRandomKey()
	checkError(err)
	receipt := contract.SendConfidentialRequest("getBiddingAddress", nil, randomKey)
	event, err := contract.Abi.Events["EncBiddingAddress"].ParseLog(receipt.Logs[0])
	checkError(err)
	encryptedBiddingAddress := event["encryptedL1Address"].([]byte)
	plainTextAddress := decryptSecretAddress(randomKey, encryptedBiddingAddress)
	fmt.Println("Owner of Bidding address:", event["owner"])
	fmt.Println("Encrypted L1 address:", hex.EncodeToString(encryptedBiddingAddress))
	fmt.Println("Decrypted L1 address:", plainTextAddress)
	return plainTextAddress
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
		log.Printf("Balance of account on Suave chain: %s:\t%s", account, bal)
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
	balance, err := L1client.BalanceAt(context.Background(), toAddress, nil)
	checkError(err)
	fmt.Println(toAddress, " has ", balance)

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
		log.Printf("Balance of account on L1 chain: %s:\t%s", to, balance)
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
	receipt := contract.SendConfidentialRequest("revealBidders", nil, nil)
	if receipt.Status == types.ReceiptStatusFailed {
		panic("Revealing Bidders tx Failed")
	}
	event, err := contract.Abi.Events["RevealBiddingAddresses"].ParseLog(receipt.Logs[0])
	checkError(err)
	bidderList := event["bidderL1"].([]common.Address)
	fmt.Println("Number of bidders: ", len(bidderList))
	fmt.Println("Revealed L1 addresses:", event["bidderL1"])
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

var path = "SealedAuctionRollup.sol/SealedAuctionRollup.json"
var fr *framework.Framework

var useLiveNet = false

func main2() {
	pause := false
	if pause {
		//mainWithPause()
		return
	}
	fmt.Println("USING THE ROLLUP AUCTION RESOLVING")
	fmt.Println("0. Setup: Deploy Oracle")
	chainIDL1 := big.NewInt(LOCAL_TESTCHAIN_ID)
	oracle := deployContractWithConstructor("OracleRollup.sol/OracleRollup.json", SuaveDevAccount, chainIDL1)
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
	fmt.Println("0.5 Fund Validator")
	validatorBalance := big.NewInt(6000000000000000)
	fundSuaveAccount(common.HexToAddress("0x3a5611E9A0dCb0d7590D408D63C9f691E669e29D"), validatorBalance)
	fmt.Println("1. Deploy Sealed Auction Rollup contract")
	//TODO: adapt inputs to something interesting (not yet used)
	auctionInSeconds := int64(10)
	auctionEndTime := big.NewInt(int64(time.Now().Unix() + auctionInSeconds))
	nftTokenID, minimalBiddingAmount := big.NewInt(420), big.NewInt(1000000000)
	nftContractAddress := L1DevAccount.Address()
	contract := deployContractWithConstructor(path, SuaveDevAccount, nftContractAddress, nftTokenID, auctionEndTime, minimalBiddingAmount, oracle.Raw().Address())

	getFieldFromContract(contract, "auctionHasStarted")

	fmt.Println("3. Print Contract Info")
	printContractInfo(contract)

	fmt.Println("4. Print Suave Chain Info")
	printSuaveChainInfoComplete()

	fmt.Println("4. Print L1 Chain Info")
	printL1ChainInfoComplete()

	fmt.Println("4.1 Setup Auction")
	setUpAuction(contract)

	fmt.Println("4.5. Start Auction")
	//startAuction(contract) //TODO: replace for this in final product
	startAuctionTest(contract)
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
	// todo: get one of the following lines to run as we need the biddingAddresses
	// biddedAddresses := getFieldFromContract(contract, "publicL1Addresses")[0].([]common.Address)
	biddedAddresses := revealBidders(contract) // need this to get the contracts but winner should have been determined

	winner := getFieldFromContract(contract, "auctionWinnerL1")[0].(common.Address)

	/* 	fmt.Println("7. Refute winner")
	   	fmt.Println("Claim as winner: ", bidders[1].Address())
	   	receipt = contract.SendConfidentialRequest("refuteWinner", []interface{}{bidders[1].Address()}, nil)
	   	printReceipt(receipt, contract, oracle) */
	sdk.SetDefaultGasLimit(10000000)

	fmt.Println("8. Print Contract Info final")
	printContractInfo(contract)

	fmt.Println("9. Return funds")
	returnFunds(biddedAddresses, winner, contract, bidders)

	fmt.Println("10. Return winning bid to auctioneer")
	returnWinningBid(winner, contract)

}

func returnWinningBid(winner common.Address, contract *framework.Contract) {
	balance, err := L1client.BalanceAt(context.Background(), winner, nil)
	checkError(err)
	fmt.Println("BEFORE returning the winning bid (Winning Bid Address): ", winner, " has balance of ", balance)
	balance, err = L1client.BalanceAt(context.Background(), SuaveDevAccount.Address(), nil)
	checkError(err)
	fmt.Println("BEFORE returning the winning bid (Auctioneer Address): ", SuaveDevAccount.Address(), " has balance of ", balance)
	getFieldFromContract(contract, "auctioneerSUAVE")
	contract = contract.Ref(SuaveDevAccount)
	contract.SendConfidentialRequest("returnValuables", []interface{}{SuaveDevAccount.Address()}, nil)
	balance, err = L1client.BalanceAt(context.Background(), winner, nil)
	checkError(err)
	fmt.Println("AFTER returning the winning bid (Winning Bid Address): ", winner, " has balance of ", balance)
	balance, err = L1client.BalanceAt(context.Background(), SuaveDevAccount.Address(), nil)
	checkError(err)
	fmt.Println("AFTER returning the winning bid (Auctioneer Address): ", SuaveDevAccount.Address(), " has balance of ", balance)
}

func returnFunds(biddedAddresses []common.Address, winnerL1 common.Address, contract *framework.Contract, bidders []*framework.PrivKey) {
	sdk.SetDefaultGasLimit(3000000)
	for i := 0; i < len(biddedAddresses); i++ {
		if biddedAddresses[i] == winnerL1 {
			fmt.Println("♛ The address: ", biddedAddresses[i], " won the auction and will not get their funds back ♛")
			continue
		}
		balance, err := L1client.BalanceAt(context.Background(), biddedAddresses[i], nil)
		checkError(err)
		fmt.Println("BEFORE Refund bid: ", biddedAddresses[i], " has balance of ", balance)
		bidContract := contract.Ref(bidders[i])
		fmt.Println("Get funds back for Suave Address:", bidders[i].Address())
		receipt := bidContract.SendConfidentialRequest("returnValuables", []interface{}{bidders[i].Address()}, nil)
		printReceipt(receipt, contract)
		balance, err = L1client.BalanceAt(context.Background(), biddedAddresses[i], nil)
		checkError(err)
		fmt.Println("AFTER Refund bid: ", biddedAddresses[i], " has balance of ", balance)
	}
}

func setUpAuction(contract *framework.Contract) {
	receipt := contract.SendConfidentialRequest("setUpAuction", nil, nil)
	printReceipt(receipt, contract)
}

// TODO: remove; used  for testing only
func printReceipt(receipt *types.Receipt, contract *framework.Contract) {
	for i := 0; i < len(receipt.Logs); i++ {
		if receipt.Logs[i].Topics[0] == contract.Abi.Events["testEvent"].ID {
			event, err := contract.Abi.Events["testEvent"].ParseLog(receipt.Logs[i])
			checkError(err)
			fmt.Println("test:", event["test"])
		} else if receipt.Logs[i].Topics[0] == contract.Abi.Events["WinnerAddress"].ID {
			event, err := contract.Abi.Events["WinnerAddress"].ParseLog(receipt.Logs[i])
			checkError(err)
			fmt.Println("winner:", event["winner"])
		} else if receipt.Logs[i].Topics[0] == contract.Abi.Events["NFTHoldingAddressEvent"].ID {
			event, err := contract.Abi.Events["NFTHoldingAddressEvent"].ParseLog(receipt.Logs[i])
			checkError(err)
			fmt.Println("NFTHoldingAddressEvent : ", event["nftHoldingAddress"])
		} else if receipt.Logs[i].Topics[0] == contract.Abi.Events["ErrorEvent"].ID {
			event, err := contract.Abi.Events["ErrorEvent"].ParseLog(receipt.Logs[i])
			checkError(err)
			fmt.Println("Error : ", event["error"])
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

func main() {
	fmt.Println("USING THE EASY AUCTION RESOLVING")
	fmt.Println("0. Setup: Deploy Oracle")
	chainIDL1 := big.NewInt(LOCAL_TESTCHAIN_ID)
	oracle := deployContractWithConstructor("Oracle.sol/Oracle.json", SuaveDevAccount, chainIDL1)
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
	path = "SealedAuction.sol/SealedAuction.json"
	fmt.Println("1. Deploy Sealed Auction contract")
	//TODO: adapt inputs to something interesting (not yet used)
	auctionInSeconds := int64(10)
	auctionEndTime := big.NewInt(int64(time.Now().Unix() + auctionInSeconds))
	nftTokenID, minimalBiddingAmount := big.NewInt(420), big.NewInt(1000000000)
	nftContractAddress := L1DevAccount.Address()
	contract := deployContractWithConstructor(path, SuaveDevAccount, nftContractAddress, nftTokenID, auctionEndTime, minimalBiddingAmount, oracle.Raw().Address())

	getFieldFromContract(contract, "auctionHasStarted")

	fmt.Println("3. Print Contract Info")
	printContractInfo(contract)

	fmt.Println("4. Print Suave Chain Info")
	printSuaveChainInfoComplete()

	fmt.Println("4. Print L1 Chain Info")
	printL1ChainInfoComplete()

	fmt.Println("4.1 Setup Auction")
	setUpAuction(contract)

	fmt.Println("4.5. Start Auction")
	//startAuction(contract) //TODO: replace for this in final product
	startAuctionTest(contract)

	fmt.Println("5. Create new account & bid")
	num_accounts := 2 // adapt accounts to be created here
	//For 2: USED GAS FOR END AUCTION: 372152
	//For 10: USED GAS FOR END AUCTION: 715376
	//For 15: USED GAS FOR END AUCTION: 929860
	//For 20: USED GAS FOR END AUCTION: 1145954
	//For 25: USED GAS FOR END AUCTION: 1362084
	// fails for 30
	bidders := make([]*framework.PrivKey, 0)
	for i := 0; i < num_accounts; i++ {
		fmt.Println("Creating account #", i)
		bidders = append(bidders, createAccount()) // appends newly created account (has funds on Suave and L1)
		bidContract := contract.Ref(bidders[i])
		placeBid(bidders[i], bidContract)
	}

	fmt.Println("6. Waiting for the auction to end...")
	time.Sleep(time.Duration(auctionInSeconds) * time.Second) //TODO: fix timing here as block.timestamp is unreliable
	fmt.Println("End auction now")
	fmt.Println("Current time: ", time.Now().Unix())
	getFieldFromContract(contract, "auctionEndTime")

	receipt = contract.SendConfidentialRequest("endAuction", nil, nil)
	if receipt.Status == types.ReceiptStatusFailed {
		panic("Revealing Bidders tx Failed")
	}
	event, err := contract.Abi.Events["RevealBiddingAddresses"].ParseLog(receipt.Logs[0])
	checkError(err)
	fmt.Println("Revealed L1 addresses:\n", event["bidderL1"])
	winnerL1 := getFieldFromContract(contract, "auctionWinnerL1")[0].(common.Address)

	sdk.SetDefaultGasLimit(uint64(300000))

	fmt.Println("7. Print Contract Info")
	printContractInfo(contract)

	fmt.Println("8. Return funds")
	returnFunds(event["bidderL1"].([]common.Address), winnerL1, contract, bidders)

	fmt.Println("9. Return winning bid to auctioneer")
	returnWinningBid(winnerL1, contract)
}
