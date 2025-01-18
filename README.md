# <h1 align="center"> Whisper-Wins Backend </h1>

## General

In essence, this repository consists of four smart contracts:

1. [**Oracle.sol**](src/utils/Oracle.sol) contains all functionality regarding fetching data from RPCs enabling our SUAVE smart contracts to access L1-chain data.
2. [**SealedAuction.sol**](src/SealedAuction.sol)  represents one sealed auction. It regulates ownership of the NFT, bidder and bidding as well as state and resolvement of the auction. Thereby, it represents the core functionality of our "backend".
3. [**FactoryContract.sol**](src/FactoryContract.sol) should initially act as the factory pattern and create an instance of an *SealedAuction* per auction. Due to complexity of implementing this in solidity however, we decided to have the auctioneer create the smart contract through the frontend. Therefore, this contract is unfinished and does not contain any used functionality within our application.
4. [**WhisperBasic.sol**](src/WhisperBasic.sol) served as a playground to get familiar with the SUAVE-framwork. Many concepts we tried out there found their way into SealedAuction contract.

The [`main.go`](main.go) file tests the functionality of our contracts (see [Testing](#Testing) for how to do this). In order to own NFTs on Sepolia we created two toy example NFT-contracts which both implement the ERC721 standard (can be found under [NFTs/](NFTs/)). The remaining contents are related to the frameworks we used.

## Workflow
In order to better grasp the workflow of our application we designed a workflow diagram using [draw.io](https://app.diagrams.net/). The following graph describes how our application works. For further details please refer to the source code.

![workflow graph of Whisper-Wins](AuctionFlowChartv2.svg)

## Limitations and Simplifications
1. **Visibility of onchain callbacks:** In order to guarantee fairness, the onchain callbacks of offchain functions (e.g.: startAuction() and startAuctionCallback()) should only be callable by it offchain counterpart. By trying to modify the visibility to "internal" and "private" we ended up in compilation errors, though. Therefore, we are left with the assumption that the callbacks are only called by the responding offchain function(s).

2. **NFT storage:** To store the NFT during the auction we currently use a static address we control. Ideally, only the contract should be able to move the NFT. Initially we wanted to achieve this by using the factory contract as the NFT-holder and let it perform access control to incoming "transferNFT" calls (only the SealedAuction related to the NFT is allowed to do this). As we decided against the implementation of the FactoryContract, the SealedAuction needs to manage the NFT by itself. Therefore, we need an address with corresponding private key. Even though we can generate such a keypair and keep it confidential using SUAVE, that would require an additional transaction by the auctioneer after deploying the contract.


## Setup

Make sure to have the latest version of `suave-geth` installed properly and can run it locally. You can find help on how to get there [here](https://suave-alpha.flashbots.net/tutorials/run-suave).
To compile the contracts you need to run `forge build`. To be able to do that you might need to install [Foundry](https://getfoundry.sh). See the [book](https://book.getfoundry.sh/getting-started/installation.html) for instructions on how to install and use Foundry.

## Genereally startup procedure:

### **Start your local suave chain:**
```bash
suave-geth --suave.dev --suave.eth.external-whitelist='*'
```

### **Compile the contracts:**
```bash
forge build
```

### **Deploy the necessary contracts:**
```bash
suave-geth spell deploy <file.sol>:<contract-name>
```

### **Call functions of the deployed contracts:**
```bash
suave-geth spell conf-request [--confidential-input <input-data>] <contract-address> '<function-name(<argument-type-list>)>' '(<argument-list>)'
```

## Get SealedAuction running:

1. Start your local suave chain: `suave-geth --suave.dev --suave.eth.external-whitelist='*'`
2. Compile the contracts: `forge build`
3. Deploy the necessary contracts: `suave-geth spell deploy SealedAuction.sol:SealedAuction` (Note: scan the generated opout for the address of the deployed contract)
4. Set up the rpc endpoints for the both Sepolia and Toliman:

- `suave-geth spell conf-request <contract-address> 'registerRPCOffchain(uint256,string)' '(33626250, https://rpc.toliman.suave.flashbots.net)'`
- `suave-geth spell conf-request --confidential-input https://sepolia.infura.io/v3/93302e94e89f41afafa250f8dce33086 <contract-address> 'registerRPCOffchain(uint256)' '(11155111)'`

5. Get your L1-bidding address with: `suave-geth spell conf-request <contract-address> 'getBiddingAddress()'`
6. You can now prepare and sign a L1-bid and send it as conf-input in a conf-request to the `'placeBid()'` method of the deployed contract.
7. When the auction has ended, call `'revealBidders()'` to display all bidding-addresses and `'endAuction()'` to move the funds accordingly.

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