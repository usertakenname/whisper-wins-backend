# <h1 align="center"> Whisper-Wins Backend </h1>

## What is Whisper-Wins?
Whisper-Wins is an application designed to facilitate sealed auctions on a blockchain. By adopting the sealed auction model, it addresses the common drawbacks of current blockchain-based auctions, such as lack of privacy, MEV attacks, and last-minute bidding. This enhancement elevates the auction experience to a new level.

## Repository Structure
In essence, this repository consists of several smart contracts:

1. [**SealedAuction.sol**](src/SealedAuction.sol) represents a sealed auction. It regulates ownership of the NFT, bidders and bidding as well as state changes and resolution of the auction. It represents the core functionality of our application.

2. [**Oracle.sol**](src/Oracle.sol) contains all functionality for fetching data from RPCs, enabling our SUAVE smart contracts to access L1-chain data and issue L1 transactions.

3. [**SealedAuctionValidator.sol**](src/ValidatorVersion/SealedAuctionValidator.sol) and [**OracleValidator.sol**](src/ValidatorVersion/OracleValidator.sol) together form an enhanced version of a sealed auction, specifically designed to address its scalability challenges. See this [chapter](#validator-version) for a detailed description.

 The [`main.go`](main.go) file serves to test the functionality of our contracts (see [this section](#run-maingo) for instructions).

## Workflow
In order to better grasp the workflow of our application we have designed workflow diagrams (see files in [visualization/](visualization/)). For further details please refer to the source code.

### Validator version
The `SealedAuctionValidator` shares the same workflow as the `SealedAuction` up until ending the auction. Instead of checking the balance of every bidder, the contract only emits all L1 addresses to be checked by validators. Hence we enter the `refute period` where everyone can suggest a winner for a specified timeframe. This suggested winner's bid will then be compared to the current suggested winner's bid. If the bid is higher, then they become the new winner of the auction. Currently, everyone can be a validator as there is no stake that is needed to suggest a winner. After a the refute period, the winner is set and can not be overruled anymore. When claiming the valuables (NFT or ETH) the auction does not directly issue the transaction. The transaction to transfer the NFT for example is signed and then emitted, for everyone to put into the mempool. For future versions these transactions might set the available gas used to 0, such that these transactions need to be included in bundles.

## Limitations of the Implementation
1. **Visibility of Onchain Callbacks:** To ensure fairness, the on-chain callbacks for off-chain functions (e.g., setUpAuction() and setUpAuctionOnchain()) should ideally only be callable by their corresponding off-chain counterparts. However, adapting the visibility to "internal" or "private" is currently not supported by SUAVE. As a result, we have to assume that these callbacks are only invoked by the respective off-chain function(s).

2. **Time constraint:** For the purpose of benchmarking, the time constraints were removed from the implementation. Thus the implementation currently does not validate if the auction time has actually ended. The modifiers (e.g. *afterAuctionTime()*, *inRefuteTime()*) can still be found in the source code and applied if necessary.

3. **Tie-Breaks in Winner Selection:** For simplicity, we make use of "first-come, first-serve" as a tie-breking rule. Depending on the actual resolution strategie, the outcome could differ. In general, the bidder who requested their bidding address first or who proposed themself first as a winner is chosen as a winner in case of a tie.

4. **Reliant on User-Generated Secret Keys:** To enable encrypted communication back to the caller, we utilize symmetric encryption (AES-256). The key material is provided by the user through the confidential inputs of a confidential request on SUAVE. While this method works, relying on user-generated keys is generally not ideal, as there's no guarantee that they are fresh, strong, or truly random. Ideally, we would prefer to communicate securely using asymmetric encryption, where the user's public address (from which the transaction was issued) serves as the basis for the encryption. Unfortunately, there is no precompile available for this purpose at the moment, which is why we have opted to use user-provided symmetric keys for now.

5. **Use of different addresses:** The application ensures privacy only if the address used for communication on the SUAVE chain differs from the one used to place a bid on the L1 chain. If the same address is used for both actions, an adversary could monitor the l1-activity of an address interacting with an auction contract on SUAVE and potentially deduce the associated bidding address and bid amount. Additionally, we strongly recommend against reusing the same SUAVE-L1 address pair for several auctions. Depending on the bidder amount, an adversary could be able to link contract interactions on SUAVE to funding of the bidding addresses on L1 once the bidding addresses for an auction are disclosed.

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
2. Initialize go.mod ```go mod init suave/whisperwins ```
3. add ```replace github.com/ethereum/go-ethereum => github.com/flashbots/suave-geth v0.2.0``` to your go.mod file
4. ```go mod tidy```
5. ```forge build```
6. Make sure that all of your fields are set in the [.env](.env) file and that the accounts provided have enough balance.
7. Provide the number of bidders as a parameter and run the go script ```go run main.go 2```. 
In order to run the validator version run ```go run src/ValidatorVersion/main.go 2```.

## Measurement of gas costs
Gas cost analysis was performed by running the [measure.go](/measurements/measure.go) file. It runs the Go script once for up to 5 bidders and captures the gas costs. The amount of iterations and the number of bidders for an auction can be adapted in the Go file. Afterwards run it with `go run measurements/measure.go`. An example execution can already be found in in [measurements.txt](./measurements.txt), running the script again will append the results to this file.
