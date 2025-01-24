# <h1 align="center"> Whisper-Wins Backend </h1>

## What is Whisper-Wins?
Whisper-Wins is an application designed to facilitate sealed auctions on the blockchain. By adopting the sealed auction model, it addresses the common drawbacks of current blockchain-based auctions, such as lack of privacy, MEV attacks, and last-minute bidding. This enhancement elevates the auction experience to a new level.

This repository contains all the necessary files for the backend of Whisper-Wins. The corresponding frontend can be found [here](https://github.com/hadwrf/whisper-wins-frontend).

## Repository Structure
In essence, this repository consists of four smart contracts:

1. [**Oracle.sol**](src/utils/Oracle.sol) contains all functionality regarding fetching data from RPCs enabling our SUAVE smart contracts to access L1-chain data and register at our server.
2. [**SealedAuction.sol**](src/SealedAuction.sol) represents a sealed auction. It regulates ownership of the NFT, bidder and bidding as well as state and resolvement of the auction. Thereby, it represents the core functionality of our "backend".
3. [**FactoryContract.sol**](src/FactoryContract.sol) should initially act as the factory pattern and create an instance of an *SealedAuction* per auction. Due to the complexity of implementing this in solidity however, we decided to have the auctioneer create the smart contract through the frontend. Therefore, this contract is unfinished and does not contain any used functionality within our application.
4. [**WhisperBasic.sol**](src/WhisperBasic.sol) served as a playground to get familiar with the SUAVE-framwork. Several of the concepts we experimented with have been integrated into **SealedAuction.sol**.

Additionally, we set up a Python server that automatically calls *revealBidders* on the SealedAuction once the bidding time has ended. This approach is implemented for convenience, so users don't need to manually trigger this action, allowing the frontend to display the winner information seamlessly. All server-related files are located in the [server/](server/) directory.

 The [`main.go`](main.go) file tests the functionality of our contracts (see [Run main.go](#run-maingo) for how to do this). In order to own NFTs on Sepolia we created two toy example NFT-contracts which both implement the ERC721 standard (can be found under [NFTs/](NFTs/)). The remaining contents are related to the frameworks we used.

## Workflow
In order to better grasp the workflow of our application we designed a workflow diagram using [draw.io](https://app.diagrams.net/). The following graph describes how our application works. For further details please refer to the source code.

![workflow graph of Whisper-Wins](AuctionFlowChartv2.svg)

## Limitations and Simplifications
1. **Visibility of Onchain Callbacks:** To ensure fairness, the on-chain callbacks for off-chain functions (e.g., startAuction() and startAuctionCallback()) should ideally be callable only by their corresponding off-chain counterparts. However, when attempting to modify the visibility to "internal" or "private," we encountered compilation errors. As a result, we have to assume that these callbacks are only invoked by the respective off-chain function(s).

2. **NFT Storage:** Ideally, only the contract should be able to move the NFT. Our initial approach was to use the *FactoryContract* as the NFT holder, allowing it to perform access control on incoming transferNFT calls (ensuring only the *SealedAuction* related to the NFT could trigger the transfer). However, since we decided against implementing the *FactoryContract*, the *SealedAuction* now needs to manage the NFT directly. <br/>
As a result, we require an address with a corresponding private key. While we could generate such a keypair and keep it confidential using SUAVE, this would require an additional transaction from the auctioneer after deploying the contract. Given that this approach is unintuitive and could disrupt the flow, we decided to store the NFT during the auction in a static address of which we know the private key.

3. **Tie-Breaks in Winner Selection:** Out of simplicity, we make use of "first-come, first-serve" as a tie-breking rule. Depending on the actual resolvement strategie (contract fetching the balances on its own, have a trusted central party do this or an optimistic rollup) the bidder who requested his or her bidding address first or who proposed him- or herself first as a winner is chosen as a winner in case of a tie.

## Required Tools and Versions
In order to run the server, you need have the latest version of [Python](https://www.python.org/downloads/) and its module `flask` installed.

For running a local SUAVE devnet, make sure to have a version of `suave-geth` installed properly and added to your path. You can find help on how to get there [here](https://suave-alpha.flashbots.net/tutorials/run-suave). <br/>
<span style="color: red;">**Important**: As we are dependent on an encryption precompile, you have to build `suave-geth` from source using [this](https://github.com/jonasgebele/suave-geth.git) repository!</span>

To compile the smart contracts you need to run `forge build`. To be able to do that you might need to install [Foundry](https://getfoundry.sh) (atleast 0.2.2). See the [book](https://book.getfoundry.sh/getting-started/installation.html) for instructions on how to install and use Foundry. We use Solidity 0.8.19 to compile the contracts.

In order to run our go files, you will need a `go` version of 1.22.XX (Note: 1.23.XX is not compatible). Help on how to install can be found [here](https://go.dev/doc/install) and on how to update an existing version can be found [here](https://gist.github.com/nikhita/432436d570b89cab172dcf2894465753).

Our application needs to control port 8001 (python server), 8545, 8546, 8551 and 8555 (all for local SUAVE devnet).

In order to place a bid, make sure to have an EOA on Sepolia with sufficient funds. Help on how to get there can be found [here](https://blog.chain.link/sepolia-eth/).


## General Deployment Procedure on a Local SUAVE Devnet:
This section explains how to deploy and interact with a smart contract on your local SUAVE-chain. However, the command line approach to do this is very limited. For example, there is no way to deploy a conract and pass arguments to the constructor. Therefore, we implemented go-scripts to test the behaviour of our contracts. To run them on your own see section [Run main.go](#run-maingo).

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

## How to Get a SealedAuction Running:
To deploy and interact with a SealedAuction, simply copy the following terminal commands:

1. Start the python server: `python3 server/server.py`
2. Start a local chain: `suave-geth --suave.dev --suave.eth.external-whitelist='*'`
3. Compile the contracts: `forge build`
4. Deploy the contract: `suave-geth spell deploy SealedAuction.sol:SealedAuction` <br/> (<span style="color: red;">Important:</span> Scan the generated output for the address of the deployed contract and insert it in the next step)
5. Get your L1-bidding address with: `suave-geth spell conf-request <contract-address> 'getBiddingAddress()'`
6. You can now place a bid by sending Sepolia ETH to your L1-bidding address.
7. Once the auction has ended, you can call `'revealBidders()'` to reveal all bidding addresses by adjusting the line of step 5 (the revealing is done automatically by the server). Depending on whether you have lost or won the bid, you can then use `'refundBid()'` or `'transferNFT()'` accordingly.

## Run main.go
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