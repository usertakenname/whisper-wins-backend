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
