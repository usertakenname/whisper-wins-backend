# <h1 align="center"> Whisper-Wins Backend </h1>
## Setup
Make sure to have the latest version of ```suave-geth``` installed properly and can run it locally. You can find help on how to get there [here](https://suave-alpha.flashbots.net/tutorials/run-suave).
To compile the contracts you need to run ```forge build```. To be able to do that you might need to install [Foundry](https://getfoundry.sh). See the [book](https://book.getfoundry.sh/getting-started/installation.html) for instructions on how to install and use Foundry.

## Genereally startup procedure:
1. Start your local suave chain: ```suave-geth --suave.dev --suave.eth.external-whitelist='*'```
2. Compile the contracts: ```forge build```
3. Deploy the necessary contracts: ```suave-geth spell deploy File.sol:Contract```
4. Call functions of the deployed contracts: ```suave-geth spell conf-request [--confidential-input <input-data>] <contract-address> '<function-name(<argument-type-list>)>' '(<argument-list>)'```

## Get SealedAuction running:
1. Start your local suave chain: ```suave-geth --suave.dev --suave.eth.external-whitelist='*'```
2. Compile the contracts: ```forge build```
3. Deploy the necessary contracts: ```suave-geth spell deploy SealedAuction.sol:SealedAuction``` (Note: scan the generated opout for the address of the deployed contract)
4. Set up the rpc endpoints for the both Sepolia and Toliman: 
- ```suave-geth spell conf-request <contract-address> 'registerRPCOffchain(uint256,string)' '(33626250, https://rpc.toliman.suave.flashbots.net)'```
- ```suave-geth spell conf-request --confidential-input https://sepolia.infura.io/v3/93302e94e89f41afafa250f8dce33086 <contract-address> 'registerRPCOffchain(uint256)' '(11155111)'```
5. Get your L1-bidding address with: ```suave-geth spell conf-request <contract-address> 'getBiddingAddress()'```
6. You can now prepare and sign a L1-bid and send it as conf-input in a conf-request to the ```'placeBid()'``` method of the deployed contract.
7. When the auction has ended, call ```'revealBidders()'``` to display all bidding-addresses and ```'endAuction()'``` to move the funds accordingly.

## Run main.go
1. Check if go is installed ```go version```
2. Initialize go.mod ```go mod init <your-package-name> ``` package name can be arbitrary (e.g. suave/whisperwins)
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