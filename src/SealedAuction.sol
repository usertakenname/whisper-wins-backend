// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

import "suave-std/Suapp.sol";
import "suave-std/Context.sol";
import "suave-std/Transactions.sol";
import "suave-std/suavelib/Suave.sol";
import "suave-std/Gateway.sol";
import "suave-std/protocols/EthJsonRPC.sol";
import "suave-std/Random.sol";
import "suave-std/crypto/Secp256k1.sol";

interface ERC20 {
    function balanceOf(address) external view returns (uint256);
}

contract SealedAuction is Suapp {
    event AuctionOpened(address contractAddr, uint256 endTimestamp, uint256 bidderAmount);

    uint256 public auctionEndTime;
    address public auctioneerSUAVE;
    address public auctioneerL1;
    uint256 public tokenId;

    // TODO delete and use parametarized constructor
/*      constructor() {
        auctioneerSUAVE = msg.sender;
        auctionEndTime = block.timestamp + (4 * 60);
        auctioneerL1 = address(0x3a5611E9A0dCb0d7590D408D63C9f691E669e29D);
        tokenId = 420;
    }  */

    // TODO delete - debugging only
    function printInfo() public returns (bytes memory) {
        emit AuctionOpened(address(this), auctionEndTime, bidderAmount);
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    // TODO how to pass constructor args to suave spell deploy?
     constructor(uint256 auctionTimeInDays, string memory nftTransferHash, uint256  chainId) {
        auctioneerSUAVE = msg.sender;
        auctionEndTime = block.timestamp + (auctionTimeInDays * 24 * 60 * 60);
    
        // set default rpc for sepolia
 /*       address[] memory peekers = new address[](1);
        peekers[0] = address(this);
        Suave.DataRecord memory record = Suave.newDataRecord(0, peekers, peekers, "rpc_endpoint");
        Suave.confidentialStore(record.id, RPC, bytes("https://sepolia.infura.io/v3/93302e94e89f41afafa250f8dce33086"));
        rpcRecords[chainId] = record.id;*/
        rpcAvailable[chainId] = true;
    
        //getNftTransfer(nftTransferHash, chainId); 
    } 

    // restrict sensitive functionality to the deployer of the smart contract
    modifier onlyAuctioneer() {
        require(msg.sender == auctioneerSUAVE);
        _;
    }

    modifier inAuctionTime() {
        require(block.timestamp <= auctionEndTime, "Auction time is over");
        _;
    }

    modifier afterAuctionTime() {
        require(block.timestamp > auctionEndTime, "Auction time not over yet");
        _;
    }

    // BIDDING RELATED FUNCTIONALITY ---------------------------------------------------------------------------------------------------------------------------------
    event RevealBiddingAddress(address bidder);
    event WinnerAddress(address winner, uint256 amount);
    event BiddingAddress(address owner, string encodedL1Address);
    event BidPlacedEvent(address bidder, uint256 value);
    function onchainCallback() public emitOffchainLogs {}

    string public PRIVATE_KEYS = "KEY";
    // mapping of public SUAVE addresses to private keys of their bidding address on L1
    mapping (address => Suave.DataId) privateKeysL1;
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
    
    // TODO how to make sure it is only called by the getBiddingAddress
    function updatePrivateKeyOnchain(address owner, Suave.DataId keyRecord) public emitOffchainLogs {
        privateKeysL1[owner] = keyRecord;
        _addressHasBid[owner] = true;
        bidderAddresses[bidderAmount++] = owner;
    }

    function getBiddingAddress() public returns (bytes memory) {
        if (_addressHasBid[msg.sender] == false) {
            require(block.timestamp <= auctionEndTime, "Auction is already over, cannot create new bidding addresses.");
            string memory privateKey = Suave.privateKeyGen(Suave.CryptoSignature.SECP256);
            bytes memory keyData = bytes(privateKey);

            address[] memory peekers = new address[](1);
            peekers[0] = address(this);
            Suave.DataRecord memory record = Suave.newDataRecord(0, peekers, peekers, "PRIVATE_KEYS");
            Suave.confidentialStore(record.id, PRIVATE_KEYS, keyData);

            address publicL1Address = Secp256k1.deriveAddress(privateKey);
            emit BiddingAddress(msg.sender, toHexString(encryptByAddress(msg.sender, publicL1Address)));

            return abi.encodeWithSelector(this.updatePrivateKeyOnchain.selector, msg.sender, record.id);                        
        } else {
            bytes memory privateL1Key = Suave.confidentialRetrieve(privateKeysL1[msg.sender], PRIVATE_KEYS);
            address publicL1Address = Secp256k1.deriveAddress(bytesToString(privateL1Key));
            emit BiddingAddress(msg.sender, toHexString(encryptByAddress(msg.sender, publicL1Address)));

            return abi.encodeWithSelector(this.onchainCallback.selector);
        }
    }

    // TODO replace with proper (AES) encryption precompile
    function encryptByAddress(address suaveAddress, address biddingAddress) internal pure returns (bytes memory) {
        return abi.encodePacked(biddingAddress);
    }

    // TODO DELETE; only for debugging
    event TxnSignature(bytes32 r, bytes32 s);

    function placeBid() public inAuctionTime() addressHasBid(msg.sender) confidential() returns (bytes memory) {
        bytes memory rlpEncodedTxn = Context.confidentialInputs();
        Transactions.EIP155 memory txn = Transactions.decodeRLP_EIP155(rlpEncodedTxn);

        // TODO what should be validated here?
        bytes memory privateL1Key = Suave.confidentialRetrieve(privateKeysL1[msg.sender], PRIVATE_KEYS);
        address publicL1Address = Secp256k1.deriveAddress(bytesToString(privateL1Key));
        require(txn.to == publicL1Address, "Unknown to address");
      //  require(rpcAvailable[txn.chainId], "Blockchain not (yet) supported.");
        require(txn.value >= 1000000000, "Value too low.");
      //  relayTransaction(rlpEncodedTxn);
        emit BidPlacedEvent(txn.to, txn.value);
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    function reclaimBid() public inAuctionTime() addressHasBid(msg.sender) returns (bytes memory) {
        // TODO transfer placed bids back
        bytes memory privateL1Key = Suave.confidentialRetrieve(privateKeysL1[msg.sender], PRIVATE_KEYS);
        address publicAddress = Secp256k1.deriveAddress(bytesToString(privateL1Key));
        uint256 value = getBalance(publicAddress);
        if (value >= 100000) {
            makeTransaction(msg.sender, address(0x3a5611E9A0dCb0d7590D408D63C9f691E669e29D), value - 100000, "Thanks for bidding", 11155111);
        } else {
            emit FundsTooLessToPayout(msg.sender);
        }
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    // END-AUCTION RELATED FUNCTIONALITY -----------------------------------------------------------------------------------------------------------------------------
    event AuctionEndedAmbigious(uint256 numberMaxBidders, uint256 bidAmount);
    event FundsTooLessToPayout(address addr);

  //  function revealBidders() public afterAuctionTime() returns (bytes memory) {
   function revealBidders() public  returns (bytes memory) {
        for (uint256 i = 0; i < bidderAmount; i++) {
            bytes memory privateL1Key = Suave.confidentialRetrieve(privateKeysL1[bidderAddresses[i]], PRIVATE_KEYS);
            address publicL1Address = Secp256k1.deriveAddress(bytesToString(privateL1Key));
            emit RevealBiddingAddress(publicL1Address);
        }
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    function endAuction() public  returns (bytes memory) {
        uint256 numberMaxBidders = 1;
        uint256 maxBid = 0;
        address winner = auctioneerSUAVE;
        for (uint256 i = 0; i < bidderAmount; i++) {
            bytes memory privateL1Key = Suave.confidentialRetrieve(privateKeysL1[bidderAddresses[i]], PRIVATE_KEYS);
            address publicL1Address = Secp256k1.deriveAddress(bytesToString(privateL1Key));
            uint256 chainId = 1234321;
            uint256 placedBid = getBalance(publicL1Address, chainId);
            if (placedBid == maxBid) {
                numberMaxBidders++;
            }
            if (placedBid > maxBid) {
                numberMaxBidders = 1;
                maxBid = placedBid;
                winner = publicL1Address;
            }
        }
        if (numberMaxBidders > 1) {
            emit AuctionEndedAmbigious(numberMaxBidders, maxBid);
/*             refundAllBids();
            refundNFT(); */
        } else {
            emit WinnerAddress(winner, maxBid);
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

    function refundBid(uint256 index) internal {
        // TODO transfer all balance to from address of ingoing tx, value = balance - gas
        bytes memory privateL1Key = Suave.confidentialRetrieve(privateKeysL1[bidderAddresses[index]], PRIVATE_KEYS);
        address publicAddress = Secp256k1.deriveAddress(bytesToString(privateL1Key));
        uint256 value = getBalance(publicAddress);
        if (value >= 100000) {
            makeTransaction(bidderAddresses[index], address(0x3a5611E9A0dCb0d7590D408D63C9f691E669e29D), value - 100000, "Thanks for bidding", 11155111);
        } else {
            emit FundsTooLessToPayout(bidderAddresses[index]);
        }
    }

    function refundAllBids() internal {
        for (uint256 i = 0; i < bidderAmount; i++) {
            refundBid(i);
        }
    }

    function refundAllBidsExcept(address winner) internal {
        for (uint256 i = 0; i < bidderAmount; i++) {
            if (bidderAddresses[i] != winner) {
                refundBid(i);
            }
        }
    }

    // TRANSACTION RELATED FUNCTIONALITY -----------------------------------------------------------------------------------------------------------------------------
    // used to relay user singed transaction to the actual L1 chain
    function relayTransaction(bytes memory rlpEncodedTxn) public {
        Transactions.EIP155 memory txn = Transactions.decodeRLP_EIP155(rlpEncodedTxn);

        string memory rpcEndpoint = bytesToString(Suave.confidentialRetrieve(rpcRecords[txn.chainId], RPC));
        Suave.HttpRequest memory request = createRawTxHttpRequest(rpcEndpoint, rlpEncodedTxn, txn.chainId);
        bytes memory response = Suave.doHTTPRequest(request);
    }

    // used to issue new transactions in order to move funds after the auction has ended (pay the auctioneer, losing bid returns)
    function makeTransaction(address suaveAddress, address toAddress, uint256 value, bytes memory payload, uint256 chainId) internal afterAuctionTime() rpcStored(chainId) addressHasBid(suaveAddress) returns (bytes memory) {
        bytes memory privateL1Key = Suave.confidentialRetrieve(privateKeysL1[suaveAddress], PRIVATE_KEYS);
        address fromAddress = Secp256k1.deriveAddress(bytesToString(privateL1Key));

        uint256 nonce = getNonce(fromAddress, chainId);

        Transactions.EIP155Request memory txnWithToAddress = Transactions
            .EIP155Request({
                to: toAddress,
                gas: 1000000,           // TODO how to determine reasonable values for gas & gasPrice?
                gasPrice: 500,
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
        bytes memory response = Suave.doHTTPRequest(request);

        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    // FETCHING RELATED FUNCTIONALITY --------------------------------------------------------------------------------------------------------------------------------
    event HttpResponse(string response);
    event RPCEndpoint(uint256 chainId, string endpointURL);
    event RPCEndpointUpdated(uint256 chainId);
    event Balance(address owner, uint256 value);
    event ERC20Balance(address coinAddr, address owner, uint256 value);
    event NonceCounter(address owner, uint256 value);

    string public RPC = "RPC";
    mapping (uint256 => Suave.DataId) rpcRecords;
    mapping (uint256 => bool) rpcAvailable;

    modifier rpcStored(uint256 chainId) {
        require(rpcAvailable[chainId], "No RPC-Endpoint available for this chain-ID.");
        _;
    }

    function updateRPCOnchain(uint256 chainId, Suave.DataId _rpcRecord) public {
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

        return abi.encodeWithSelector(this.updateRPCOnchain.selector, chainId, record.id);
    }

/*     function registerRPCOffchain(uint256 chainId, string memory endpointURL) public returns (bytes memory) {
        address[] memory peekers = new address[](1);
        peekers[0] = address(this);

        Suave.DataRecord memory record = Suave.newDataRecord(0, peekers, peekers, "rpc_endpoint");
        Suave.confidentialStore(record.id, RPC, bytes(endpointURL));

        return abi.encodeWithSelector(this.updateRPCOnchain.selector, chainId, record.id);
    } */

    function getNftTransfer(string memory txHash, uint256 chainId) internal {
        bytes memory response = getTxByHash(txHash, chainId);
        emit HttpResponse(bytesToString(response)); // TODO parse the answer to get the from address and required nft information (if any) and set it accorfingly
        auctioneerL1 = address(0);
        tokenId = 0;
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
        bytes memory hexAlphabet = "0123456789abcdef";
        bytes memory str = new bytes(2 + data.length * 2);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < data.length; i++) {
            str[2 + i * 2] = hexAlphabet[uint256(uint8(data[i] >> 4))];
            str[3 + i * 2] = hexAlphabet[uint256(uint8(data[i] & 0x0f))];
        }
        return string(str);
    }
}
