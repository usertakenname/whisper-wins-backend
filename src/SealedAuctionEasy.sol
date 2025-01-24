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

interface Oracle {
    function getNFTOwnedByEasy(
        address _nftContract,
        uint256 _tokenId
    ) external returns (bytes memory);
    function endAuctionEasy(address[] memory) external returns (bytes memory);
    function transferEasy(
        address returnAddress,
        Suave.DataId suaveDataID
    ) external returns (bytes memory);
}

contract SealedAuctionEasy is Suapp {
    address public auctioneerSUAVE; // TODO: which fields should be public?
    address public auctionWinnerL1 = address(0);
    uint256 public winningBid = 0;
    address public auctionWinnerSuave = address(0);
    address public oracle; // TODO: hardcode to static address once we've deployed the final version
    address public nftHoldingAddress;
    address public nftContract;
    uint256 public tokenId;
    uint256 public auctionEndTime;
    uint256 public minimalBid;
    bool public auctionHasStarted = false;



    // TODO delete - debugging only
    event AuctionInfo(
        address auctioneerSUAVE,
        address nftHoldingAddress,
        address nftContract,
        uint256 tokenId,
        uint256 auctionEndTime,
        uint256 minimalBid,
        bool auctionHasStarted,
        address auctionWinnerL1,
        address auctionWinnerSuave,
        uint256 winningBid,
        address[] revealedL1Addresses
    );
    function printInfo() public returns (bytes memory) {
        emit AuctionInfo(
            auctioneerSUAVE,
            nftHoldingAddress,
            nftContract,
            tokenId,
            auctionEndTime,
            minimalBid,
            auctionHasStarted,
            auctionWinnerL1,
            auctionWinnerSuave,
            winningBid,
            revealedL1Addresses
        );
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }




    constructor(
        address nftContractAddress,
        uint256 nftTokenId,
        uint256 _auctionEndTime,
        uint256 minimalBiddingAmount,
        address oracleAddress //TODO: delete from constructor once it is static
    ) {
        auctioneerSUAVE = msg.sender;
        nftContract = nftContractAddress;
        tokenId = nftTokenId;
        auctionEndTime = _auctionEndTime;
        minimalBid = minimalBiddingAmount;
        oracle = oracleAddress; //TODO: delete from constructor once it is static
    }

    // restrict sensitive functionality to the deployer of the smart contract
    modifier onlyAuctioneer() {
        require(
            msg.sender == auctioneerSUAVE,
            "You are not the auctioneer of this auction"
        );
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
        require(
            block.timestamp <= auctionEndTime,
            string.concat(
                "Auction time is over! Current timestamp: ",
                toString(block.timestamp),
                " > auction ending timestamp: ",
                toString(auctionEndTime)
            )
        );
        _;
    }

    modifier afterAuctionTime() {
        require(auctionHasStarted, "Auction not yet started");
        require(
            block.timestamp >= auctionEndTime,
            string.concat(
                "Auction time not over yet! Current timestamp: ",
                toString(block.timestamp),
                " < auction ending timestamp: ",
                toString(auctionEndTime)
            )
        );
        _;
    }

    modifier validAuctionEndTime() {
        require(
            block.timestamp < auctionEndTime,
            string.concat(
                "Auction ending time is over already! Current timestamp: ",
                toString(block.timestamp),
                " > auction endin timestamp: ",
                toString(auctionEndTime)
            )
        );
        _;
    }

    modifier onlyOracle() {
        require(
            msg.sender == oracle,
            "Only the oracle can perform this operation"
        );
        _;
    }

    modifier winnerRegistered() {
        require(auctionWinnerL1 != address(0), "No L1-winner registered");
        require(auctionWinnerSuave != address(0), "No SUAVE-winner registered");
        _;
    }

    modifier notWinnerSuave() {
        require(
            !checkIsWinner(msg.sender),
            "You cannot refund your bid as you are the winner of the auction"
        );
        _;
    }

    modifier isWinnerSuave() {
        require(
            checkIsWinner(msg.sender),
            "You are the winner of the auction and can therefore not do this action"
        );
        _;
    }

    function checkIsWinner(
        address checkSuaveAddress
    )
        internal
        view
        addressHasBid(checkSuaveAddress)
        winnerRegistered
        returns (bool)
    {
        return checkSuaveAddress == auctionWinnerSuave;
    }

    // simple callback to publish offchain events
    function onchainCallback() public emitOffchainLogs {}

    // SETUP AUCTION RELATED FUNCTIONALITY ---------------------------------------------------------------------------------------------------------------------------
    event NFTHoldingAddressEvent(address nftHoldingAddress);

    // this function generates (if not yet done) the nftHoldingAddres for the auction and emits it
    function setUpAuction()
        public
        confidential
        onlyAuctioneer
        returns (bytes memory)
    {
        if (nftHoldingAddress == address(0)) {
            string memory privateKey = Suave.privateKeyGen(
                Suave.CryptoSignature.SECP256
            );
            bytes memory keyData = bytes(privateKey);

            address[] memory stores = new address[](1);
            stores[0] = address(this);
            address[] memory peekers = new address[](2);
            peekers[0] = address(this);
            peekers[1] = oracle; // oracle can also see private keys
            Suave.DataRecord memory record = Suave.newDataRecord(
                0,
                peekers,
                stores,
                PRIVATE_KEYS
            );
            Suave.confidentialStore(record.id, PRIVATE_KEYS, keyData);
            address _nftHoldingAddress = Secp256k1.deriveAddress(privateKey);
            emit NFTHoldingAddressEvent(_nftHoldingAddress);
            return
                abi.encodeWithSelector(
                    this.createNFTaddressCallback.selector,
                    _nftHoldingAddress,
                    record.id
                );
        }
        emit NFTHoldingAddressEvent(nftHoldingAddress);
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    function createNFTaddressCallback(
        address _nftHoldingAddress,
        Suave.DataId keyRecord
    ) public {
        nftHoldingAddress = _nftHoldingAddress;
        privateKeysL1[address(this)] = keyRecord; // The lookup address for the NFT key holding address is the auction contracts address
    }

    // START AUCTION RELATED FUNCTIONALITY ---------------------------------------------------------------------------------------------------------------------------
    event AuctionOpened(
        address contractAddr,
        address nftContractAddress,
        uint256 nftTokenId,
        uint256 endTimestamp,
        uint256 minimalBiddingAmount
    );

    function startAuctionCallback() public emitOffchainLogs {
        auctionHasStarted = true;
        emit AuctionOpened(
            address(this),
            nftContract,
            tokenId,
            auctionEndTime,
            minimalBid
        );
    }

    // TODO: delete this after we deploy a nft contract in go file and have nft transfers in there
    function startAuctionTest() public pure returns (bytes memory) {
        return abi.encodeWithSelector(this.startAuctionCallback.selector);
    }

    function startAuction() public onlyAuctioneer auctionNotStarted validAuctionEndTime returns (bytes memory) {
        Oracle oracleRPC = Oracle(oracle);
        return oracleRPC.getNFTOwnedByEasy(nftContract, tokenId);
    }

    function confirmNFTowner(
        address NFTowner
    ) external view onlyOracle returns (bytes memory) {
        require(
            NFTowner == nftHoldingAddress,
            "The NFT was not transferred yet"
        );
        return abi.encodeWithSelector(this.startAuctionCallback.selector);
    }

    // BIDDING RELATED FUNCTIONALITY ---------------------------------------------------------------------------------------------------------------------------------
    event RevealBiddingAddresses(address[] bidderL1);
    event WinnerAddress(address winner);
    event EncBiddingAddress(address owner, bytes encryptedL1Address);

    string public PRIVATE_KEYS = "KEY";

    // mapping of public SUAVE addresses to private keys of their bidding address on L1
    mapping(address => Suave.DataId) privateKeysL1;
    mapping(address => bool) _addressHasBid;
    // keep track of the bidders: bidderAmount and mapping from i-th bidder to its SUAVE-address
    uint256 public bidderAmount = 0;
    mapping(uint256 => address) bidderAddresses;
    // store all L1 bidding addresses once revealed
    address[] public revealedL1Addresses = new address[](0);

    modifier addressHasBid(address owner) {
        require(
            _addressHasBid[owner],
            string.concat(
                "No bidding address related to this address: ",
                toHexString(abi.encodePacked(owner))
            )
        );
        _;
    }

    modifier senderHasBid() {
        require(
            _addressHasBid[msg.sender],
            string.concat(
                "No bidding address related to msg.sender: ",
                toHexString(abi.encodePacked(msg.sender))
            )
        );
        _;
    }

    modifier addressWithoutBid(address owner) {
        require(
            _addressHasBid[owner] == false,
            "Address already owns a bidding address"
        );
        _;
    }

    function registerBiddingPrivateKeyCallback(
        address owner,
        Suave.DataId keyRecord
    ) public emitOffchainLogs {
        privateKeysL1[owner] = keyRecord;
        _addressHasBid[owner] = true;
        bidderAddresses[bidderAmount++] = owner;
    }

    // If caller has no bidding address so far, create a new bidding address and/else emit it in an encrypted fashion (secret is provided in confidential Input)
    function getBiddingAddress() public confidential returns (bytes memory) {
        bytes memory secretKey = Context.confidentialInputs();
        if (_addressHasBid[msg.sender] == false) {
            string memory privateKey = Suave.privateKeyGen(
                Suave.CryptoSignature.SECP256
            );
            bytes memory keyData = bytes(privateKey);

            address[] memory stores = new address[](1);
            stores[0] = address(this);
            address[] memory peekers = new address[](2);
            peekers[0] = address(this);
            peekers[1] = oracle; // oracle can also see private keys
            Suave.DataRecord memory record = Suave.newDataRecord(
                0,
                peekers,
                stores,
                PRIVATE_KEYS
            );
            Suave.confidentialStore(record.id, PRIVATE_KEYS, keyData);

            address publicL1Address = Secp256k1.deriveAddress(privateKey);
            bytes memory encrypted = encryptAddress(
                secretKey,
                abi.encodePacked(publicL1Address)
            );
            emit EncBiddingAddress(msg.sender, encrypted);
            return
                abi.encodeWithSelector(
                    this.registerBiddingPrivateKeyCallback.selector,
                    msg.sender,
                    record.id
                );
        } else {
            bytes memory privateL1Key = Suave.confidentialRetrieve(
                privateKeysL1[msg.sender],
                PRIVATE_KEYS
            );
            address publicL1Address = Secp256k1.deriveAddress(
                string(privateL1Key)
            );
            bytes memory encrypted = encryptAddress(
                secretKey,
                abi.encodePacked(publicL1Address)
            );
            emit EncBiddingAddress(msg.sender, encrypted);
            return abi.encodeWithSelector(this.onchainCallback.selector);
        }
    }

    function encryptAddress(
        bytes memory secretKey,
        bytes memory publicL1Address
    ) internal returns (bytes memory) {
        return Suave.aesEncrypt(secretKey, abi.encodePacked(publicL1Address));
    }

    // END-AUCTION RELATED FUNCTIONALITY -----------------------------------------------------------------------------------------------------------------------------
    function endAuction()
        public
        confidential
        afterAuctionTime
        returns (bytes memory)
    {
        if (revealedL1Addresses.length == 0) {
            Oracle oracleRpc = Oracle(oracle);
            address[] memory toRevealBiddersL1 = new address[](bidderAmount);
            for (uint256 i = 0; i < bidderAmount; i++) {
                bytes memory privateL1Key = Suave.confidentialRetrieve(
                    privateKeysL1[bidderAddresses[i]],
                    PRIVATE_KEYS
                );
                address publicL1Address = Secp256k1.deriveAddress(
                    string(privateL1Key)
                );
                toRevealBiddersL1[i] = (publicL1Address);
            }
            emit RevealBiddingAddresses(toRevealBiddersL1);
            return oracleRpc.endAuctionEasy(toRevealBiddersL1);
        }
        emit RevealBiddingAddresses(revealedL1Addresses);
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    function endAuctionCallback(
        address _winner,
        uint256 _winningBid,
        address[] memory _l1Addresses
    ) external confidential afterAuctionTime onlyOracle returns (bytes memory) {
        for (uint256 i = 0; i < bidderAmount; i++) {
            bytes memory privateL1Key = Suave.confidentialRetrieve(
                privateKeysL1[bidderAddresses[i]],
                PRIVATE_KEYS
            );
            address publicL1Address = Secp256k1.deriveAddress(
                string(privateL1Key)
            );
            if (publicL1Address == _winner) {
                return
                    abi.encodeWithSelector(
                        this.endAuctionOnchain.selector,
                        _winner,
                        bidderAddresses[i],
                        _winningBid,
                        _l1Addresses
                    );
            }
        }
        revert(string.concat("Winner L1 address not part of the auction: ",  toHexString(abi.encodePacked(_winner))));
        // return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    function endAuctionOnchain(
        address _winnerL1,
        address _winnerSUAVE,
        uint256 _winningBid,
        address[] memory _l1Addresses
    ) public afterAuctionTime emitOffchainLogs {
        auctionWinnerL1 = _winnerL1;
        winningBid = _winningBid;
        auctionWinnerSuave = _winnerSUAVE;
        revealedL1Addresses = _l1Addresses;
    }

    function claimWinningBid(
        address returnAddressL1
    )
        external
        confidential
        onlyAuctioneer
        afterAuctionTime
        winnerRegistered
        returns (bytes memory)
    {
        Oracle oracleRPC = Oracle(oracle);
        return
            oracleRPC.transferEasy(
                returnAddressL1,
                privateKeysL1[auctionWinnerSuave]
            );
    }

    function refundBid(
        address returnAddressL1
    )
        external
        confidential
        notWinnerSuave
        afterAuctionTime
        senderHasBid
        returns (bytes memory)
    {
        Oracle oracleRPC = Oracle(oracle);
        return
            oracleRPC.transferEasy(returnAddressL1, privateKeysL1[msg.sender]);
    }

    function refundNFT() internal auctionStarted {
        // TODO transfer back to auctioneerL1
    }

    function transferNFT(address returnAddressL1) public isWinnerSuave {
        // TODO transfer nft to winner from address of ingoing tx
        // TODO transfer funds in winner address to auctioneerL1
    }

    // HELPER FUNCTIONALITY ------------------------------------------------------------------------------------------------------------------------------------------

    function toHexString(
        bytes memory data
    ) internal pure returns (string memory) {
        return LibString.toHexString(data);
    }

    function toString(uint256 value) internal pure returns (string memory str) {
        return LibString.toString(value);
    }
}
