# <h1 align="center"> Sealed-Bid Auctions via TEE-Backed Confidential Compute Blockchains </h1>

## Repository Structure
In essence, this repository consists of several smart contracts:

1. [**SealedAuction.sol**](src/SealedAuction.sol) represents a sealed auction. It regulates ownership of the NFT, bidders and bidding as well as state changes and resolution of the auction. It represents the core functionality of our application.

2. [**Oracle.sol**](src/Oracle.sol) contains all functionality for fetching data from RPCs, enabling our SUAVE smart contracts to access L1-chain data and issue L1 transactions.

3. [**SealedAuctionProposer.sol**](src/ProposerVersion/SealedAuctionProposer.sol) and [**OracleProposer.sol**](src/ProposerVersion/OracleProposer.sol) together form an enhanced version of a sealed auction, specifically designed to address its scalability challenges. See this [chapter](#Proposer-version) for a detailed description.

 The [`main.go`](main.go) file serves to test the functionality of our contracts (see [this section](#run-maingo) for instructions). Running this file will completely simulate the auction behavior by deploying an auction contract on SUAVE. Then the NFT will be moved on Sepolia, and bids will be placed. After the auction is over, all of the bids & the NFT will be returned to the auctioneer.

### Proposer version
The `SealedAuctionProposer` shares the same workflow as the `SealedAuction` up until ending the auction. Instead of checking the balance of every bidder, the contract only emits all L1 addresses to be checked by proposers. Hence we enter the `refute period` where everyone can suggest a winner for a specified timeframe. This suggested winner's bid will then be compared to the current suggested winner's bid. If the bid is higher, then they become the new winner of the auction. Currently, everyone can be a proposer as there is no stake that is needed to suggest a winner. After a the refute period, the winner is set and can not be overruled anymore. When claiming the valuables (NFT or ETH) the auction does not directly issue the transaction. The transaction to transfer the NFT for example is signed and then emitted, for everyone to put into the mempool. For future versions these transactions might set the available gas used to 0, such that these transactions need to be included in bundles.

## Required Tools and Versions
For running a local SUAVE devnet, make sure to have a version of `suave-geth` installed properly and added to your path. You can find help in the repository on [Github](https://github.com/flashbots/suave-geth).

To compile the smart contracts, run `forge build`. To be able to do that you might need to install [Foundry](https://getfoundry.sh) (atleast 0.2.2). See the [book](https://book.getfoundry.sh/getting-started/installation.html) for instructions on how to install and use Foundry. Make sure all dependencies are set up accordingly. When in doubt, run `forge install flashbots/suave-std` and `forge install OpenZeppelin/openzeppelin-contracts`. The contracts are compiled with Solidity 0.8.20.

In order to run the Go files, you will need a `Go` version of 1.22.XX (Note: 1.23.XX is not compatible). Help on how to install can be found [here](https://go.dev/doc/install) and on how to update an existing version can be found [here](https://gist.github.com/nikhita/432436d570b89cab172dcf2894465753).

The local SUAVE chain runs on port 8545 by default. You can change this by appending `--http.port <value>` when running the local chain.

### Setting up enviroment variables
Create a new `.env` file at the root level, following the structure of `.env.example`. Adjust it as follows:
- **L1_PRIVATE_KEY:** In order to place a bid, make sure to have an EOA on Sepolia with sufficient funds. Help on how to get there can be found [here](https://blog.chain.link/sepolia-eth/). Once you got one, replace `<YOUR-PRIVATE-L1-KEY>` with it. This L1 address serves as the auctioneer and also provides funds for all of the bidders, so make sure it has enough funds. For a small auction there should be 0.1 ETH on this account.

- **NFT_CONTRACT_ADDRESS AND NFT_TOKEN_ID:** The address and corresponding token ID of the NFT to be auctioned. This NFT must be owned by the account specified in `L1_PRIVATE_KEY`.

- **SUAVE_DEV_PRIVATE_KEY:** The account on SUAVE that makes the requests to the auction contract. This account is also responsible for funding all bidders. By default, the account with the private key `6c45335a22461ccdb978b78ab61b238bad2fae4544fb55c14eb096c875ccfc52` is funded on the local SUAVE chain.

- **ALCHEMY_API_KEY AND ETHERSCAN_API_KEY:** In order to deploy a functioning Oracle contract, Alchemy and Etherscan API-Key are required to access their RPC-services. Sign up [here](https://auth.alchemy.com/?redirectUrl=https%3A%2F%2Fdashboard.alchemy.com%2Fsignup%2F%3Fa%3D) and [here](https://etherscan.io/login) in order to obtain one and paste them in the file accordingly.
- **SEPOLIA_API_KEY:** Additionally, an Infura API key is needed to use an L1 client. Learn how to sign up [here](https://developer.metamask.io/register).


## Basics: General Deployment Procedure on a Local SUAVE Devnet:
This section explains how to deploy and interact with a smart contract on your local SUAVE-chain. However, the command line approach is limited in its functionality. For example, you cannot deploy a contract and pass arguments to the constructor. Therefore, we implemented Go-scripts to test the behavior of our contracts. To run them, refer to section [Run main.go](#run-maingo).

1. **Start your local suave chain:**
```bash
suave-geth --suave.dev --suave.eth.external-whitelist='*'
```

2. **Compile the contracts:**
```bash
forge build
```

3. **Deploy the necessary contracts:**
```bash
suave-geth spell deploy <file.sol>:<contract-name>
```

4. **Call functions of the deployed contracts [with confidential input]:**
```bash
suave-geth spell conf-request [--confidential-input <input-data>] <contract-address> '<function-name(<argument-type-list>)>' '(<argument-list>)'
```

## Run main.go
1. Check if Go is installed ```go version```
2. Initialize go.mod ```go mod init suave/sealedauction```
3. add ```replace github.com/ethereum/go-ethereum => github.com/flashbots/suave-geth v0.2.0``` to your go.mod file
4. ```go mod tidy```
5. ```forge build```
6. Make sure that all of your fields are set in the [.env](.env) file and that the accounts provided have enough balance.
7. Provide the number of bidders as a parameter and run the go script ```go run main.go 2```. 
In order to run the proposer version run ```go run src/ProposerVersion/main.go 2```.

## Measurement of gas costs
Gas cost analysis was performed by running the [measure.go](/measurements/measure.go) file. It runs the Go script once for up to 5 bidders and captures the gas costs. The amount of iterations and the number of bidders for an auction can be adapted in the Go file. Afterwards run it with `go run measurements/measure.go`. An example execution can already be found in in [measurements.txt](./measurements.txt), running the script again will append the results to this file.
