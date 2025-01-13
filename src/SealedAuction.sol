// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

import "suave-std/Suapp.sol";
import "suave-std/Context.sol";
import "suave-std/Transactions.sol";
import "suave-std/suavelib/Suave.sol";
import "suave-std/Gateway.sol";
import "suave-std/protocols/EthJsonRPC.sol";
import "suave-std/crypto/Secp256k1.sol";
import "solady/src/utils/JSONParserLib.sol";
import "solady/src/utils/LibString.sol";

interface ERC20 {
    function balanceOf(address) external view returns (uint256);
}

contract SealedAuction is Suapp {
    address public auctioneerL1; // TODO: which fields should be public?
    address public auctioneerSUAVE;
    address public auctionWinner; 
    uint256 public winningBid;
    address public server = address(0xB5fEAfbDD752ad52Afb7e1bD2E40432A485bBB7F); //kettle address so far TODO: change to serverAddress
    address nftHoldingAddress = address(0x3a5611E9A0dCb0d7590D408D63C9f691E669e29D);
    address public nftContract;
    uint256 public tokenId;
    uint256 public auctionTimeSpan;
    uint256 public auctionEndTime;
    uint256 public minimalBid;
    uint256 public finalBlockNumber; // on ETH Chain
    bool public auctionHasStarted = false;

    // TODO delete - debugging only
    event AuctionInfo(address auctioneerL1, address auctioneerSUAVE, address nftHoldingAddress, address nftContract, uint256 tokenId, uint256 auctionTimeSpan,
                    uint256 auctionEndTime, uint256 minimalBid, bool auctionHasStarted, address winner, uint256 finalBlockNumber, uint256 winningBid);
    function printInfo() public returns (bytes memory) {
        emit AuctionInfo(auctioneerL1, auctioneerSUAVE, nftHoldingAddress, nftContract, tokenId, auctionTimeSpan, auctionEndTime, minimalBid, auctionHasStarted,auctionWinner,finalBlockNumber, winningBid);
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    constructor(address beneficiaryAddress, address nftContractAddress, uint256 nftTokenId, uint256 auctionTimeInDays, uint256 minimalBiddingAmount) {
        auctioneerSUAVE = msg.sender;
        auctioneerL1 = beneficiaryAddress;
        nftContract = nftContractAddress;
        tokenId = nftTokenId;
        auctionTimeSpan = auctionTimeInDays * 24 * 60 * 60;
        minimalBid = minimalBiddingAmount;
        winningBid = 0;
        auctionWinner = address(0);
    }

    // restrict sensitive functionality to the deployer of the smart contract
    modifier onlyAuctioneer() {
        require(msg.sender == auctioneerSUAVE);
        _;
    }

    // modifiers to restrict auction-state sensitive functionality 
    modifier auctionStarted() {
        require(auctionHasStarted, "Auction not yet started");
        _;
    }

    modifier auctionNotStarted() {
        require(!auctionHasStarted, "Auction has already started");
        _;
    }

    modifier inAuctionTime() {
        require(auctionHasStarted, "Auction not yet started");
        require(block.timestamp <= auctionEndTime, "Auction time is over");
        _;
    }

    modifier afterAuctionTime() {
        require(auctionHasStarted, "Auction not yet started");
        require(block.timestamp >= auctionEndTime, "Auction time not over yet");
        _;
    }

    modifier serverCall(){
        require(msg.sender == server, "Only the server can perform this operation");
        _;
    }

    modifier winnerRegistered(){
        require(auctionWinner != address(0));
        _;
    }


    function getEthBlockNumber(uint256 chainID) private rpcStored(chainID) returns (uint256){
        string[] memory headers = new string[](1);
        headers[0] = "Content-Type: application/json"; 
        bytes memory _body = abi.encodePacked(
                '{"jsonrpc":"2.0", "method": "eth_blockNumber", "params": [], "id": "',
                toString(chainID),
                '"}'
                ); 
        Suave.HttpRequest memory request = Suave.HttpRequest({
            url: string(Suave.confidentialRetrieve(rpcRecords[chainID], RPC)),
            method: "POST",
            headers: headers,
            body: _body,
            withFlashbotsSignature: false,
            timeout: 7000
        });        
        bytes memory response = Suave.doHTTPRequest(request);
        return JSONParserLib.parseUintFromHex(stripQuotes(JSONParserLib.value(getJSONField(response, "result"))));
    }


    function registerFinalBlockNumber(uint256 _finalBlockNr) public emitOffchainLogs {
        finalBlockNumber = _finalBlockNr;
    }

    // Idea is that anyone can claim themselves as the winner and the contract checks the balance of the account when the auction has ended (by final block number)
    // Have a server monitor the revealed addresses and call this method with the winner
    function refuteWinner(address addressToCheck,uint256 chainID) public rpcStored(chainID) confidential() addressHasBid(addressToCheck) returns (bytes memory) {
        string[] memory headers = new string[](1);
        headers[0] = "Content-Type: application/json";
        bytes memory privateL1Key = Suave.confidentialRetrieve(privateKeysL1[addressToCheck], PRIVATE_KEYS);
        address publicL1Address = Secp256k1.deriveAddress(bytesToString(privateL1Key)); 
        bytes memory _body = abi.encodePacked(
                '{"jsonrpc":"2.0", "method": "eth_getProof", "params": ["',
                toHexString(abi.encodePacked(publicL1Address)),
                '",[],"',
                LibString.toMinimalHexString(finalBlockNumber), 
                //"latest", 
                '"], "id": "',
                toString(chainID),
                '"}'
                ); 
        Suave.HttpRequest memory request = Suave.HttpRequest({
            url: string(Suave.confidentialRetrieve(rpcRecords[chainID], RPC)),
            method: "POST",
            headers: headers,
            body: _body,
            withFlashbotsSignature: false,
            timeout: 7000
        });        
        bytes memory response = Suave.doHTTPRequest(request);
        uint256 balance = JSONParserLib.parseUintFromHex(stripQuotes(JSONParserLib.value(JSONParserLib.at(getJSONField(response, "result"),'"balance"'))));
        if (balance > winningBid) {
        return abi.encodeWithSelector(this.overrideWinner.selector,addressToCheck,balance);
        }
        emit WinnerAddress(auctionWinner);
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    function overrideWinner(address newWinner, uint256 newWinningBalance) public emitOffchainLogs {
        emit WinnerAddress(newWinner);
        auctionWinner = newWinner;
        winningBid = newWinningBalance;
    }

    
    function registerWinner() public confidential() serverCall() returns (bytes memory){
        bytes memory confInput = Context.confidentialInputs();
        address winner =  address(bytes20(confInput));
        return abi.encodeWithSelector(this.updateWinner.selector,winner);
    }

    function updateWinner(address winner) public emitOffchainLogs {
        auctionWinner = winner;
    }

    // simple callback to publish offchain events
    function onchainCallback() public emitOffchainLogs {}

    // START AUCTION RELATED FUNCTIONALITY ---------------------------------------------------------------------------------------------------------------------------
    event AuctionOpened(address contractAddr, address nftContractAddress, uint256 nftTokenId, uint256 endTimestamp, uint256 minimalBiddingAmount);

    function startAuctionCallback() public emitOffchainLogs {
        auctionHasStarted = true;
        auctionEndTime = block.timestamp + auctionTimeSpan;
        emit AuctionOpened(address(this), nftContract, tokenId, auctionEndTime, minimalBid);
    }
    
    function startAuction() public onlyAuctioneer()  auctionNotStarted()  returns (bytes memory) {
        //TODO uncomment when NFT transfer functionality is completed
/*         address ownerAddress = getNFTOwnedBy(nftContract, tokenId, 11155111);
        require(ownerAddress == nftHoldingAddress, "Transfer the NFT before starting the auction."); */

        return abi.encodeWithSelector(this.startAuctionCallback.selector);
    }

    // BIDDING RELATED FUNCTIONALITY ---------------------------------------------------------------------------------------------------------------------------------
    event RevealBiddingAddress(address bidder);
    event WinnerAddress(address winner);
    event EncBiddingAddress(address owner, string encryptedL1Address);

    string public PRIVATE_KEYS = "KEY";
    string public RETURN_ADDRESS = "ADDR";

    // mapping of public SUAVE addresses to 1. private keys of their bidding address on L1 and 2. the L1 return address for their bids
    mapping (address => Suave.DataId) privateKeysL1;
    mapping (address => Suave.DataId) bidReturnAddressesL1;
    mapping (address => bool) _addressHasBid;
    // keep track of the bidders
    uint256 public bidderAmount = 0;
    mapping (uint256 => address) bidderAddresses;

    modifier addressHasBid(address owner) {
        require(_addressHasBid[owner], "No bidding address related to this sender.");
        _;
    }

    modifier addressWithoutBid(address owner) {
        require(_addressHasBid[owner] == false, "Address already owns bidding address.");
        _;
    }
    
    // TODO how to make sure callbacks are only called by the responding offchain functions
    function updatePrivateKeyCallback(address owner, Suave.DataId keyRecord) public emitOffchainLogs {
        privateKeysL1[owner] = keyRecord;
        _addressHasBid[owner] = true;
        bidderAddresses[bidderAmount++] = owner;
    }

    // emits the bidding address in a encrypted fashion, creates a new one if user has no bidding address so far
    function getBiddingAddress() public confidential() returns (bytes memory) {
        if (_addressHasBid[msg.sender] == false) {
           // require(block.timestamp <= auctionEndTime, "Auction is already over, cannot create new bidding addresses."); TODO uncomment when NFT transfer is implemented
            string memory privateKey = Suave.privateKeyGen(Suave.CryptoSignature.SECP256);
            bytes memory keyData = bytes(privateKey);

            address[] memory peekers = new address[](1);
            peekers[0] = address(this);
            Suave.DataRecord memory record = Suave.newDataRecord(0, peekers, peekers, PRIVATE_KEYS);
            Suave.confidentialStore(record.id, PRIVATE_KEYS, keyData);

            address publicL1Address = Secp256k1.deriveAddress(privateKey);
            emit EncBiddingAddress(msg.sender, toHexString(encryptForAddress(msg.sender, publicL1Address)));

            return abi.encodeWithSelector(this.updatePrivateKeyCallback.selector, msg.sender, record.id);                        
        } else {
            bytes memory privateL1Key = Suave.confidentialRetrieve(privateKeysL1[msg.sender], PRIVATE_KEYS);
            address publicL1Address = Secp256k1.deriveAddress(bytesToString(privateL1Key));
            emit EncBiddingAddress(msg.sender, toHexString(encryptForAddress(msg.sender, publicL1Address)));

            return abi.encodeWithSelector(this.onchainCallback.selector);
        }
    }

    // TODO replace with proper (AES) encryption precompile
    function encryptForAddress(address suaveAddress, address biddingAddress) internal pure returns (bytes memory) {
        
        return abi.encodePacked(biddingAddress);
    }

    // TODO DELETE; only for debugging
    event TxnSignature(bytes32 r, bytes32 s);

    function placeBidCallback(address owner, Suave.DataId returnAddress) public {
        bidReturnAddressesL1[owner] = returnAddress;
    }

    // Note: To ensure your funds are returned, you must place at least one bid through the auction contract's placeBid() method.
    //       Otherwise, the return address remains undetermined for the contract and your funds may be stuck.
    //       Regardless of how many individual bids were made, the last bid issued by a suave address determines its L1 return address.
    function placeBid() public inAuctionTime() addressHasBid(msg.sender) confidential() returns (bytes memory) {
        bytes memory rlpEncodedTxn = Context.confidentialInputs();
        Transactions.EIP155 memory txn = Transactions.decodeRLP_EIP155(rlpEncodedTxn);

        // validate the bid transaction
        bytes memory privateL1Key = Suave.confidentialRetrieve(privateKeysL1[msg.sender], PRIVATE_KEYS);
        address publicL1Address = Secp256k1.deriveAddress(bytesToString(privateL1Key));
        require(txn.to == publicL1Address, "Unknown to address.");
        require(rpcAvailable[txn.chainId], "Blockchain not (yet) supported.");
        require(txn.value >= minimalBid, "Value less than minimal bid.");

        relayTransaction(rlpEncodedTxn);

        // update the address to which the bids are returned to
        address[] memory peekers = new address[](1);
        peekers[0] = address(this);
        Suave.DataRecord memory record = Suave.newDataRecord(0, peekers, peekers, RETURN_ADDRESS);
        Suave.confidentialStore(record.id, RETURN_ADDRESS, abi.encode(txn.to)); // TODO question: how to get the from/issuer address of the txn?

        return abi.encodeWithSelector(this.placeBidCallback.selector, record.id);
    }

    // allows the bidder to back out before the auction has ended
    function reclaimBid() public inAuctionTime() addressHasBid(msg.sender) returns (bytes memory) {
        address returnAddress = address(bytes20(Suave.confidentialRetrieve(bidReturnAddressesL1[msg.sender], RETURN_ADDRESS)));
        bytes memory privateL1Key = Suave.confidentialRetrieve(privateKeysL1[msg.sender], PRIVATE_KEYS);
        address publicAddress = Secp256k1.deriveAddress(bytesToString(privateL1Key));
        uint256 value = getBalance(publicAddress);
        uint gasPrice = getGasPrice() * 2;
        if (value >= 21000 * gasPrice) {
            makeTransaction(msg.sender, returnAddress, gasPrice, value - (21000 * gasPrice), "", 11155111);
        } else {
            emit FundsTooLessToPayout(msg.sender);
        }
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    // END-AUCTION RELATED FUNCTIONALITY -----------------------------------------------------------------------------------------------------------------------------
    event NoBidder();
    event AuctionEndedAmbigious(uint256 numberMaxBidders, uint256 bidAmount);
    event FundsTooLessToPayout(address addr);

    //reveal Bidders runs out of gas at 35 bidders 
  //  function revealBidders() public afterAuctionTime() returns (bytes memory) {
   function revealBidders() public  returns (bytes memory) {
        for (uint256 i = 0; i < bidderAmount; i++) {
            bytes memory privateL1Key = Suave.confidentialRetrieve(privateKeysL1[bidderAddresses[i]], PRIVATE_KEYS);
            address publicL1Address = Secp256k1.deriveAddress(bytesToString(privateL1Key));
            emit RevealBiddingAddress(publicL1Address);
        }
        uint256 currentEthBlockNumber = getEthBlockNumber(1234321);
        return abi.encodeWithSelector(this.registerFinalBlockNumber.selector,currentEthBlockNumber);
    }


    function endAuction2() public   returns (bytes memory) {
        emit WinnerAddress(auctionWinner);
        /*
            refundAllBidsExcept(winner);
            transferNFT(winner); */
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    function endAuction() public afterAuctionTime() returns (bytes memory) {
        uint256 numberMaxBidders = bidderAmount;
        uint256 maxBid = 0;
        address winner = auctioneerSUAVE;
        uint256 validBids = 0;
        for (uint256 i = 0; i < bidderAmount; i++) {
            bytes memory privateL1Key = Suave.confidentialRetrieve(privateKeysL1[bidderAddresses[i]], PRIVATE_KEYS);
            address publicL1Address = Secp256k1.deriveAddress(bytesToString(privateL1Key));
            uint256 placedBid = getBalance(publicL1Address);
            if (placedBid >= minimalBid) {
                validBids++;
                if (placedBid == maxBid) {
                    numberMaxBidders++;
                }
                if (placedBid > maxBid) {
                    numberMaxBidders = 1;
                    maxBid = placedBid;
                    winner = publicL1Address;
                }
            }
        }
        // TODO implement refunding functions
        if (validBids == 0) {
            emit NoBidder();
            refundNFT();
        } else if (numberMaxBidders > 1) {
            emit AuctionEndedAmbigious(numberMaxBidders, maxBid);
/*             refundAllBids();
            refundNFT(); */
        } else {
            emit WinnerAddress(winner);
/*             refundAllBidsExcept(winner);
            transferNFT(winner); */
        }
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    function refundNFT() internal {
        // TODO transfer back to auctioneerL1
    }

    function transferNFT(address winner) internal {
        // TODO transfer nft to winner from address of ingoing tx
        // TODO transfer funds in winner address to auctioneerL1
    }

    function refundBid(uint256 index, uint256 gasPrice) internal {
        address suaveAddress = bidderAddresses[index];
        address returnAddress = address(bytes20(Suave.confidentialRetrieve(bidReturnAddressesL1[suaveAddress], RETURN_ADDRESS)));
        bytes memory privateL1Key = Suave.confidentialRetrieve(privateKeysL1[suaveAddress], PRIVATE_KEYS);
        address publicAddress = Secp256k1.deriveAddress(bytesToString(privateL1Key));
        uint256 value = getBalance(publicAddress);
        if (value >= 21000 * gasPrice) {
            makeTransaction(suaveAddress, returnAddress, gasPrice, value - (21000 * gasPrice), "", 11155111);
        } else {
            emit FundsTooLessToPayout(suaveAddress);
        }
    }

    function refundAllBids() internal {
        uint gasPrice = getGasPrice() * 2;
        for (uint256 i = 0; i < bidderAmount; i++) {
            refundBid(i, gasPrice);
        }
    }

    function refundAllBidsExcept(address winner) internal {
        uint gasPrice = getGasPrice() * 2;
        for (uint256 i = 0; i < bidderAmount; i++) {
            if (bidderAddresses[i] != winner) {
                refundBid(i, gasPrice);
            }
        }
    }

    // TRANSACTION RELATED FUNCTIONALITY -----------------------------------------------------------------------------------------------------------------------------
    // used to relay user singed transaction to the actual L1 chain
    function relayTransaction(bytes memory rlpEncodedTxn) public {
        Transactions.EIP155 memory txn = Transactions.decodeRLP_EIP155(rlpEncodedTxn);

        require(rpcAvailable[txn.chainId], "No RPC-Endpoint available for this chain-ID.");
        string memory rpcEndpoint = bytesToString(Suave.confidentialRetrieve(rpcRecords[txn.chainId], RPC));
        Suave.HttpRequest memory request = createRawTxHttpRequest(rpcEndpoint, rlpEncodedTxn, txn.chainId);
        Suave.doHTTPRequest(request);
    }

    // used to issue new transactions in order to move funds after the auction has ended (pay the auctioneer, losing bid returns)
    function makeTransaction(address suaveAddress, address toAddress, uint256 gasPrice, uint256 value, bytes memory payload, uint256 chainId) internal afterAuctionTime() rpcStored(chainId) addressHasBid(suaveAddress) returns (bytes memory) {
        bytes memory privateL1Key = Suave.confidentialRetrieve(privateKeysL1[suaveAddress], PRIVATE_KEYS);
        address fromAddress = Secp256k1.deriveAddress(bytesToString(privateL1Key));
        uint256 nonce = getNonce(fromAddress, chainId);

        Transactions.EIP155Request memory txnWithToAddress = Transactions
            .EIP155Request({
                to: toAddress,
                gas: 21000,
                gasPrice: gasPrice,
                value: value,
                nonce: nonce,
                data: payload,
                chainId: chainId
            });

        Transactions.EIP155 memory txn = Transactions.signTxn(txnWithToAddress, string(privateL1Key));
        emit TxnSignature(txn.r, txn.s); // just for debugging purposes, TODO delete
        bytes memory rlpEncodedTxn = Transactions.encodeRLP(txn);

        string memory rpcEndpoint = bytesToString(Suave.confidentialRetrieve(rpcRecords[chainId], RPC));
        Suave.HttpRequest memory request = createRawTxHttpRequest(rpcEndpoint, rlpEncodedTxn, chainId);
        Suave.doHTTPRequest(request);

        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    // FETCHING RELATED FUNCTIONALITY --------------------------------------------------------------------------------------------------------------------------------
    event HttpResponse(string response);
    event RPCEndpoint(uint256 chainId, string endpointURL); // TODO debug only, delete
    event RPCEndpointUpdated(uint256 chainId);
    event Balance(address owner, uint256 value);
    event ERC20Balance(address coinAddr, address owner, uint256 value);
    event NonceCounter(address owner, uint256 value);

    // store base url for rpc endpoints per chainId
    string public RPC = "RPC";
    mapping (uint256 => Suave.DataId) rpcRecords;
    mapping (uint256 => bool) rpcAvailable;

    modifier rpcStored(uint256 chainId) {
        require(rpcAvailable[chainId], "No RPC-Endpoint available for this chain-ID.");
        _;
    }

    function updateRPCCallback(uint256 chainId, Suave.DataId _rpcRecord) public {
        rpcRecords[chainId] = _rpcRecord;
        rpcAvailable[chainId] = true;
        emit RPCEndpointUpdated(chainId);
    }

    function printRPCEndpoint(uint256 chainId) public rpcStored(chainId) returns (bytes memory) {
        emit RPCEndpoint(chainId, bytesToString(Suave.confidentialRetrieve(rpcRecords[chainId], RPC)));
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    function registerRPCOffchain(uint256 chainId) public returns (bytes memory) {
        bytes memory rpcData = Context.confidentialInputs();
        address[] memory peekers = new address[](1);
        peekers[0] = address(this);

        Suave.DataRecord memory record = Suave.newDataRecord(0, peekers, peekers, "rpc_endpoint");
        Suave.confidentialStore(record.id, RPC, rpcData);

        return abi.encodeWithSelector(this.updateRPCCallback.selector, chainId, record.id);
    }

// TODO: function overloading not working with main.go
/*     function registerRPCOffchain(uint256 chainId, string memory endpointURL) public returns (bytes memory) {
        address[] memory peekers = new address[](1);
        peekers[0] = address(this);

        Suave.DataRecord memory record = Suave.newDataRecord(0, peekers, peekers, "rpc_endpoint");
        Suave.confidentialStore(record.id, RPC, bytes(endpointURL));

        return abi.encodeWithSelector(this.updateRPCCallback.selector, chainId, record.id);
    } */

    function getNFTOwnedBy(address _nftContract, uint256 _tokenId, uint256 _chainId) public rpcStored(_chainId) returns (address) {
        string[] memory headers = new string[](1);
        headers[0] = "Content-Type: application/json";

        string memory baseURL = bytesToString(Suave.confidentialRetrieve(rpcRecords[_chainId], RPC));
        string memory path = string.concat("/getOwnersForToken?contractAddress=", toHexString(abi.encodePacked(_nftContract)), "&tokenId=", string(abi.encodePacked(_tokenId)));

        bytes memory response = Suave.doHTTPRequest(Suave.HttpRequest({
            url: string.concat(baseURL, path),
            method: "GET",
            headers: headers,
            body: '',
            withFlashbotsSignature: false,
            timeout: 7000
        })); 
        return address(uint160(JSONParserLib.parseUintFromHex(JSONParserLib.value(JSONParserLib.at(getJSONField(response, "owners"), 0))))); 
    }

    function getTxByHash(string memory txHash, uint256 chainId) public rpcStored(chainId) returns (bytes memory) {
        string[] memory headers = new string[](1);
        headers[0] = "Content-Type: application/json";

        Suave.HttpRequest memory request = Suave.HttpRequest({
            url: bytesToString(Suave.confidentialRetrieve(rpcRecords[chainId], RPC)),
            method: "POST",
            headers: headers,
            body: abi.encodePacked(
                '{"jsonrpc":"2.0", "method": "eth_getTransactionByHash", "params": ["',
                txHash,
                '"], "id": ',
                chainId,
                '}'
            ),
            withFlashbotsSignature: false,
            timeout: 7000
        });        
        return Suave.doHTTPRequest(request);
    }

    function createRawTxHttpRequest(string memory endpointURL, bytes memory rlpEncodedTxn, uint256 chainId) internal view rpcStored(chainId) returns (Suave.HttpRequest memory) {
        string[] memory headers = new string[](1);
        headers[0] = "Content-Type: application/json";

        return Suave.HttpRequest({
            url: endpointURL,
            method: "POST",
            headers: headers,
            body: abi.encodePacked(
                '{"jsonrpc":"2.0", "method": "eth_sendRawTransaction", "params": ["',
                toHexString(rlpEncodedTxn),
                '"], "id": ',
                chainId,
                "}"
            ),
            withFlashbotsSignature: false,
            timeout: 7000
        });
    }

    // get Gas-Price
    function getGasPrice() internal returns (uint256) {
        return getGasPrice(11155111);
    }

    function getGasPrice(uint256 chainId) internal rpcStored(chainId) returns (uint256) {
        string memory endpoint = bytesToString(Suave.confidentialRetrieve(rpcRecords[chainId], RPC));
        
        string[] memory headers = new string[](1);
        headers[0] = "Content-Type: application/json";

        bytes memory response = Suave.doHTTPRequest(Suave.HttpRequest({
            url: endpoint,
            method: "POST",
            headers: headers,
            body: abi.encodePacked(
                '{"jsonrpc":"2.0", "method": "eth_gasPrice", "params": [], "id": ',
                chainId,
                "}"
            ),
            withFlashbotsSignature: false,
            timeout: 7000
        }));

        // Hex-number answer in json["result"], eg: {"jsonrpc":"2.0","id":11155111,"result":"0x2138251e3"}
        uint256 gasPrice = JSONParserLib.parseUintFromHex(stripQuotes(JSONParserLib.value(getJSONField(response, "result"))));
        return gasPrice;
    }


    // print/get NONCE
    function printNonce(address account) public returns (bytes memory) {
        return printNonce(account, 11155111);
    }

    function printNonce(address account, uint256 chainId) public rpcStored(chainId) returns (bytes memory) {
        uint256 nonce = getNonce(account, chainId);
        emit NonceCounter(account, nonce);
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    function getNonce(address account) internal returns (uint256) {
        return getNonce(account, 11155111);
    }

    function getNonce(address account, uint256 chainId) internal rpcStored(chainId) returns (uint256) {
        string memory endpoint = bytesToString(Suave.confidentialRetrieve(rpcRecords[chainId], RPC));
        EthJsonRPC jsonrpc = new EthJsonRPC(endpoint);
        return jsonrpc.nonce(account);
    }

    // print/get Balance
    function printBalance(address account) public returns (bytes memory) {
        return printBalance(account, 11155111);
    }

    function printBalance(address account, uint256 chainId) public rpcStored(chainId) returns (bytes memory) {
        uint256 balance = getBalance(account, chainId);
        emit Balance(account, balance);
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    function getBalance(address account) internal returns (uint256) {
        //return getBalance(account, 11155111);
    return getBalance(account, 1234321);
    }

    function getBalance(address account, uint256 chainId) internal rpcStored(chainId) returns (uint256) {
        string memory endpoint = bytesToString(Suave.confidentialRetrieve(rpcRecords[chainId], RPC));
        EthJsonRPC jsonrpc = new EthJsonRPC(endpoint);
        return jsonrpc.balance(account);
    }

    // print/get ERC20Balance
    function printERC20Balance(address coinAddr, address account) public returns (bytes memory) {
        return printERC20Balance(coinAddr, account, 11155111);
    }

    function printERC20Balance(address coinAddr, address account, uint256 chainId) public rpcStored(chainId) returns (bytes memory) {
        uint256 balance = getERC20Balance(coinAddr, account, chainId);
        emit ERC20Balance(coinAddr, account, balance);
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    function getERC20Balance(address coinAddr, address account) internal returns (uint256) {
        return getERC20Balance(coinAddr, account, 11155111);
    }

    function getERC20Balance(address coinAddr, address account, uint256 chainId) internal rpcStored(chainId) returns (uint256) {
        string memory endpoint = bytesToString(Suave.confidentialRetrieve(rpcRecords[chainId], RPC));
        Gateway gateway = new Gateway(endpoint, coinAddr);
        ERC20 token = ERC20(address(gateway));
        return token.balanceOf(account);
    }

    // HELPER FUNCTIONALITY ------------------------------------------------------------------------------------------------------------------------------------------
        function bytesToString(bytes memory data) internal pure returns (string memory) {
        uint256 length = data.length;
        bytes memory chars = new bytes(length);

        for (uint i = 0; i < length; i++) {
            chars[i] = data[i];
        }

        return string(chars);
    }
    

    function toHexString(bytes memory data) internal pure returns (string memory) {
        return LibString.toHexString(data);
    }

    function toString(uint256 value) internal pure returns (string memory str) {
        return LibString.toString(value);
    }

    function getJSONField(bytes memory json, string memory key) internal pure returns (JSONParserLib.Item memory) {
        JSONParserLib.Item memory item = JSONParserLib.parse(string(json));
        JSONParserLib.Item memory err = JSONParserLib.at(item, '"error"');
        if (!JSONParserLib.isUndefined(err)) {
            revert(JSONParserLib.value(err));
        }
        return JSONParserLib.at(item, string.concat('"', key, '"'));
    }

    //method in EthJsonRPC
    function stripQuotes(string memory input) internal pure returns (string memory) {
        bytes memory inputBytes = bytes(input);
        bytes memory result = new bytes(inputBytes.length - 2);

        for (uint256 i = 1; i < inputBytes.length - 1; i++) {
            result[i - 1] = inputBytes[i];
        }

        return string(result);
    }
    //method in EthJsonRPC
    function stripQuotesAndPrefix(string memory s) internal pure returns (string memory) {
        bytes memory strBytes = bytes(s);
        bytes memory result = new bytes(strBytes.length - 4);
        for (uint256 i = 3; i < strBytes.length - 1; i++) {
            result[i - 3] = strBytes[i];
        }
        return string(result);
    }

}
