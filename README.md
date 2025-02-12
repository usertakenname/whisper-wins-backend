# <h1 align="center"> Whisper-Wins Backend </h1>

## What is Whisper-Wins?
Whisper-Wins is an application designed to facilitate sealed auctions on a blockchain. By adopting the sealed auction model, it addresses the common drawbacks of current blockchain-based auctions, such as lack of privacy, MEV attacks, and last-minute bidding. This enhancement elevates the auction experience to a new level.

This repository contains all the necessary files for the backend of Whisper-Wins. The corresponding frontend can be found [here](https://github.com/hadwrf/whisper-wins-frontend).

## Repository Structure
In essence, this repository consists of a bunch of smart contracts:

1. [**Oracle.sol**](src/utils/Oracle.sol) contains all functionality regarding fetching data from RPCs enabling our SUAVE smart contracts to access L1-chain data and issue L1-transactions.
2. [**SealedAuction.sol**](src/SealedAuction.sol) represents a sealed auction. It regulates ownership of the NFT, bidders and bidding as well as state changes and resolvement of the auction. Thereby, it represents the core functionality of our application.
3. [**SealedAuctionRollup.sol**](src/SealedAuctionRollup.sol) and [**OracleRollup.sol**](src/utils/OracleRollup.sol) together form an enhanced version of a sealed auction, specifically designed to tackle its scalability challenges (see [Limitations and Simplifications](#Limitations-and-Simplifications) for more details). Due to the complexities it adds, it is not used in the final Whisper-Wins application.
4. [**FactoryContract.sol**](src/FactoryContract.sol) should initially act as the factory pattern and create an instance of an *SealedAuction* per auction. Due to the complexity of implementing this in solidity however, we decided to have the auctioneer deploy the smart contract through the frontend. Therefore, this contract is unfinished and does not contain any used functionality within our application.
5. [**WhisperBasic.sol**](src/WhisperBasic.sol) served as a playground to get familiar with the SUAVE-framwork. Several of the concepts we experimented with have been integrated into **SealedAuction.sol**.

Additionally, we set up a python server that acts as a validator in the resolvement of a *SealedAuctionRollup*. This approach is implemented for convenience, so users don't need to manually trigger and pay fot this action, allowing the frontend to display winner information seamlessly. All server-related files are located in the [server/](server/) directory.

 The [`main.go`](main.go) file serves to test the functionality of our contracts (see [Run main.go](#run-maingo) for how to do this). In order to own NFTs on Sepolia we created two toy example NFT-contracts which both implement the ERC721 standard (can be found under [src/NFTs/](src/NFTs/)). The remaining contents are related to the frameworks we used.

## Workflow
In order to better grasp the workflow of our application we designed a workflow diagram using [draw.io](https://app.diagrams.net/) (files can be found in [visualization/](visualization/)). The following graph describes how our application works. For further details please refer to the source code.

Note: For better readability, we have omitted the requirement that each participant must call the smart contract in order to claim their respective outcomes. To complete the picture of the last three steps in the sequence diagram, a preceding call to claim() on the Suave blockchain contract is necessary which then issues the funds-moving transaction on the ETH chain.

![workflow graph of Whisper-Wins](visualization/AuctionFlowChartv2.svg)

## Limitations and Simplifications
1. **Visibility of Onchain Callbacks:** To ensure fairness, the on-chain callbacks for off-chain functions (e.g., setUpAuction() and setUpAuctionOnchain()) should ideally only be callable by their corresponding off-chain counterparts. However, when attempting to modify the visibility to "internal" or "private," we encountered compilation errors. As a result, we have to assume that these callbacks are only invoked by the respective off-chain function(s).

2. **Poor Scalability:** In a *SealedAuction*, the contract itself resolves the auction by fetching the balance of every bidder's bidding address at a specific block height. This process is both gas-intensive and time-consuming, as we lack tools to leverage parallelism in the EVM. Consequently, we can easily exceed the gas limit when attempting to resolve auctions. This implicit limit on the amount of bidders is impractical for real-world auctions.<br/>
To address this, we explored two potential solutions. One solution involves a trusted third party that monitors auction contract deployments and does the heavy lifting once the auction ends. It first calls a function where the auction contract reveals all bidding addresses, then computes the winner on its own computing resources and sets the winner in the contract accordingly. However, this approach introduces the need for trust in the third party and makes the auction process reliant on this service.<br/>
To eliminate this dependency and the associated trust assumptions, we designed a protocol that uses an optimistic rollup to determine the auction winner. The overall approach remains the same, but instead of a single trusted central party, anyone can propose a winner to the contract. The contract verifies that the proposed winner has a higher valid bid (placed within the auction period) than the current selected one and updates the winner accordingly. In this design, once the auction time concludes, a secondary period is opened during which anyone can propose a winner. After this period expires, the winner is finalized and the funds can be distributed. While it's possible that there is a valid higher bid but noone proposed it in time, the auction will still resolve, and the result is persistent.<br/>
The key insight behind this approach is that both the auctioneer and the highest bidder have a shared interest in ensuring the correct winner is selected. Additionally, the previously mentioned server can now serve as a validator (run by anyone), performing the same task as before. However, if there's an error or compromise, the result can be corrected by anyone, removing the reliance on a single central authority.<br/>
Given the added complexity this version introduces into the overall auction workflow, we've decided to stick with the more straightforward, in-contract resolution strategy for now. However, we took the time to explore and implement a rollup-based version of a sealed auction (see [SealedAuctionRollup.sol](src/SealedAuctionRollup.sol)) as a potential alternative.

3. **Tie-Breaks in Winner Selection:** Out of simplicity, we make use of "first-come, first-serve" as a tie-breking rule. Depending on the actual resolvement strategie, the outcome could differ though. In general, the bidder who requested his or her bidding address first or who proposed him- or herself first as a winner is chosen as a winner in case of a tie. This is how it works in detail:
- Contract fetching the balances on its own (*SealedAuction.sol*): Among all the bidders who have placed the highest bid, the winner will be the one who requested his bidding address first.
- Have our python server as a trusted central party: Since our server retrieves the balances in the same order as the contract, the outcome will be the same.
- Make use of an optimistic rollup: The first proposed winner will remain the winner if another bidder with the same bidding amount is later proposed. Therefore, the resulting winner is depending on the order in which they are presented to the contract.

4. **Relient on User-Generated Secret Keys:** To enable encrypted communication back to the caller, we utilize symmetric encryption (AES-256). The key material is provided by the user through the confidential inputs of a confidential request on SUAVE. While this method works, relying on user-generated keys is generally not ideal, as there's no guarantee that they are fresh, strong, or truly random. Ideally, we would prefer to communicate securely using asymmetric encryption, where the user's public address (from which the transaction was issued) serves as the basis for the encryption. Unfortunately, there is no precompile available for this purpose at the moment, which is why we have opted to use user-provided symmetric keys for now.

5. **Use of different addresses:** The application ensures privacy only if the address used for communication on the SUAVE chain differs from the one used to place a bid on the L1 chain. If the same address is used for both actions, an adversary could monitor the l1-activity of an address interacting with an auction contract on SUAVE and potentially deduce the associated bidding address and bid amount. Additionally, we strongly recommend against reusing the same SUAVE-L1 address pair for several auctions. Depending on the bidder amount, an adversary could be able to link contract interactions on SUAVE to funding of the bidding addresses on L1 once the bidding addresses for an auction are disclosed.

## Required Tools and Versions
In order to run the server, you need have the latest version of [Python](https://www.python.org/downloads/) and its module `flask` installed.

For running a local SUAVE devnet, make sure to have a version of `suave-geth` installed properly and added to your path. You can find help on how to get there [here](https://suave-alpha.flashbots.net/tutorials/run-suave).

To compile the smart contracts you need to run `forge build`. To be able to do that you might need to install [Foundry](https://getfoundry.sh) (atleast 0.2.2). See the [book](https://book.getfoundry.sh/getting-started/installation.html) for instructions on how to install and use Foundry. Make sure all dependencies are set up accordingly. When in doubt, run `forge install flashbots/suave-std` and `forge install OpenZeppelin/openzeppelin-contracts`. We use Solidity 0.8.20 to compile the contracts.

In order to run our go files, you will need a `go` version of 1.22.XX (Note: 1.23.XX is not compatible). Help on how to install can be found [here](https://go.dev/doc/install) and on how to update an existing version can be found [here](https://gist.github.com/nikhita/432436d570b89cab172dcf2894465753).

For running our application locally, you need to open port 8001 (python server), 8545, 8546, 8551 and 8555 (all four for local chains).

### Setting up enviroment variables
Create a new `.env` file on the root level, following the structure of `.env.example`. Adjust it like this:
- **L1_PRIVATE_KEY:** In order to place a bid, make sure to have an EOA on Sepolia with sufficient funds. Help on how to get there can be found [here](https://blog.chain.link/sepolia-eth/). Once you got one, replace `<YOUR-PRIVATE-L1-KEY>` with it.
- **ALCHEMY_API_KEY and ETHERSCAN_API_KEY:** Alchemy and Etherscan require an API-Key to access their RPC-services. Sign up [here](https://auth.alchemy.com/?redirectUrl=https%3A%2F%2Fdashboard.alchemy.com%2Fsignup%2F%3Fa%3D) and [here](https://etherscan.io/login) in order to obtain one and paste them in the file accordingly.
- **SERVER_PRIVATE_KEY:** If you want to run our validator service aswell, you need another L1 private key for it. Similar to L1_PRIVATE_KEY, provide a key such that the service can issue transactions.


## General Deployment Procedure on a Local SUAVE Devnet:
This section explains how to deploy and interact with a smart contract on your local SUAVE-chain. However, the command line approach to do this is very limited. For example, there is no way to deploy a contract and pass arguments to the constructor. Therefore, we implemented go-scripts to test the behaviour of our contracts. To run them on your own refer to section [Run main.go](#run-maingo).

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
Note: The test currently does not cover NFT deployment or NFT transfers. You can either expand the tests to include these scenarios or add shortcuts in the smart contracts to bypass the "NFT has been transferred to the nftHoldingAddress" check.
1. Check if go is installed ```go version```
2. Initialize go.mod ```go mod init suave/whisperwins ```
3. add ```replace github.com/ethereum/go-ethereum => github.com/flashbots/suave-geth v0.2.0``` to your go.mod file
4. ```go mod tidy```
5. ```forge build``` & copy your generated your-file.json to ~/go/pkd/mod/github.com/suapp-examples@v0.0.0-20241031122241-896ca6742979/out/your-file.sol/your-file.json (need to create /out/your-file.sol directories)
6. Start your local suave chain: ```suave-geth --suave.dev --suave.eth.external-whitelist='*'```
7. To run your own L1 testnet refer to section [Start L1 testnet](#start-l1-testnet) otherwise connect to Sepolia like this:
8. Add your Sepolia private key to [.env](.env) file. This will be used to fund accounts for bidding.
9. ```go run main.go```


### Start L1 testnet
1. Initialize your local L1 chain with genesis block (geth needed): ```geth init --datadir myDatadir genesis.json``` (this creates myDatadir/geth directory)
2. For L1 Testing run ```geth --dev --http --http.port 8555 --datadir myDatadir/ --ipcpath ~/ipc/```
3. You can use ```geth attach ~/ipc``` to attach an console to the geth chain & ```suave-geth attach /tmp/geth.ipc``` for the suave chain