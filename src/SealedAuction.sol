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

interface Oracle {
    function getEthBlockNumber() external returns (bytes memory);
    function getNFTOwnedBy(
        address _nftContract,
        uint256 _tokenId
    ) external returns (bytes memory);
    function transfer(
        address returnAddress,
        uint256 finalETHBlock,
        Suave.DataId suaveDataID
    ) external returns (bytes memory);
    function getBalanceAtBlockExternal(
        address l1Address,
        uint256 finalETHBlock
    ) external returns (bytes memory);
    function registerContract(
        address contract_address,
        uint256 end_time
    ) external returns (bytes memory);
}

contract SealedAuction is Suapp {
    address public auctioneerSUAVE;// TODO: which fields should be public?
    address public auctionWinnerL1;
    address public auctionWinnerSuave;
    uint256 public winningBid;
    address public oracle;
    address nftHoldingAddress;
        //address(0x929e17E4B2085130a415C5f69Cfb1Fbef163bDAd); //test Address
    // address(0x3a5611E9A0dCb0d7590D408D63C9f691E669e29D); TODO: change to this
    address public nftContract;
    uint256 public tokenId;
    uint256 public auctionEndTime;
    uint256 public minimalBid;
    uint256 public finalBlockNumber; // on ETH Chain
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
        uint256 finalBlockNumber,
        uint256 winningBid
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
            finalBlockNumber,
            winningBid
        );
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    constructor(
        address nftContractAddress,
        uint256 nftTokenId,
        uint256 _auctionEndTime,
        uint256 minimalBiddingAmount,
        address oracleAddress
    ) {
        auctioneerSUAVE = msg.sender;
        nftContract = nftContractAddress;
        tokenId = nftTokenId;
        auctionEndTime = _auctionEndTime;
        minimalBid = minimalBiddingAmount;
        winningBid = 0;
        auctionWinnerL1 = address(0);
        auctionWinnerSuave = address(0);
        oracle = oracleAddress;
    }

    // restrict sensitive functionality to the deployer of the smart contract
    modifier onlyAuctioneer() {      
        require(msg.sender == auctioneerSUAVE, "You are not the auctioneer of this auction");
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
                " Auction time is over! Currently timestamp: ",
                toString(block.timestamp),
                " > auction endTimestamp ",
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
                " Auction time not over yet! Currently timestamp: ",
                toString(block.timestamp),
                " < auction endTimestamp ",
                toString(auctionEndTime)
            )
        );
        _;
    }

    modifier validAuctionEndTime() {
        require(
            block.timestamp < auctionEndTime,
            string.concat(
                " Auction end time is over already! Currently timestamp: ",
                toString(block.timestamp),
                " > auction endTimestamp ",
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
        require(auctionWinnerL1 != address(0));
        require(auctionWinnerSuave != address(0));
        _;
    }

    modifier notWinnerSuave() {
        require(
            !checkIsWinner(msg.sender),
            "You can not refund your Bid as you are the winner of the auction"
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
    ) internal addressHasBid(checkSuaveAddress) winnerRegistered returns (bool) {
/*         bytes memory privateL1Key = Suave.confidentialRetrieve(
            privateKeysL1[checkAddress],
            PRIVATE_KEYS
        );
        address publicL1Address = Secp256k1.deriveAddress(string(privateL1Key));
        return publicL1Address == auctionWinnerL1; */
        return checkSuaveAddress == auctionWinnerSuave;
    }

    function getEthBlockNumber() private returns (bytes memory) {
        Oracle oracleRPC = Oracle(oracle);
        return oracleRPC.getEthBlockNumber();
    }

    function registerFinalBlockNumber(
        uint256 _finalBlockNr
    ) external view onlyOracle returns (bytes memory) {
        return
            abi.encodeWithSelector(
                this.registerFinalBlockNumberOnchain.selector,
                _finalBlockNr
            );
    }

    function registerFinalBlockNumberOnchain(
        uint256 _finalBlockNr
    ) public emitOffchainLogs {
        finalBlockNumber = _finalBlockNr;
    }

    event testEvent(string inString ,bytes inBytes);

    function setUpAuction() public confidential onlyAuctioneer  returns (bytes memory){
        if (nftHoldingAddress == address(0)){
             string memory privateKey = Suave.privateKeyGen(
                Suave.CryptoSignature.SECP256
            );
            bytes memory keyData = bytes(privateKey);

            address[] memory peekers = new address[](2);
            peekers[0] = address(this);
            peekers[1] = oracle; // oracle can also see private keys
            Suave.DataRecord memory record = Suave.newDataRecord(
                0,
                peekers,
                peekers,
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

    function createNFTaddressCallback(address _nftHoldingAddress, Suave.DataId keyRecord) public {
        nftHoldingAddress = _nftHoldingAddress;
        privateKeysL1[address(this)] = keyRecord; // The lookup address for the NFT key holding address is the auction contracts address
    }

    // Idea is that anyone can claim themselves as the winner and the contract checks the balance of the account when the auction has ended (by final block number)
    // Have a server monitor the revealed addresses and call this method with the winner
    function refuteWinner(
        address addressToCheck
    )
        public
        confidential
        addressHasBid(addressToCheck)
        afterAuctionTime
        returns (bytes memory)
    {
        bytes memory privateL1Key = Suave.confidentialRetrieve(
            privateKeysL1[addressToCheck],
            PRIVATE_KEYS
        );
        address publicL1Address = Secp256k1.deriveAddress(string(privateL1Key));
        Oracle oracleRPC = Oracle(oracle);
        return
            oracleRPC.getBalanceAtBlockExternal(
                publicL1Address,
                finalBlockNumber
            );
    }

    //######################################################
    // simplification: only oracle can register winner (no optimistic rollup)
    // todo: anyone can call this and we trust it?
    // addressToCheck is L1 Address
    function registerWinner(
        address addressToCheckL1,
        uint256 _winningBid
    )
        public
        confidential
        afterAuctionTime
        auctionStarted
        returns (bytes memory)
    {
        for (uint256 i = 0; i < bidderAmount; i++) {
            bytes memory privateL1Key = Suave.confidentialRetrieve(
                privateKeysL1[bidderAddresses[i]],
                PRIVATE_KEYS
            );
            address publicL1Address = Secp256k1.deriveAddress(
                string(privateL1Key)
            );
            if(publicL1Address == addressToCheckL1){
                        return
            abi.encodeWithSelector(this.updateWinner.selector, publicL1Address,bidderAddresses[i],_winningBid);
            }
        }
        emit ErrorEvent(string.concat("Something went wrong registering the winner ",toHexString(abi.encodePacked(addressToCheckL1))));
        abi.encodeWithSelector(this.onchainCallback.selector);
    }

    event ErrorEvent(string error);
    //######################################################
    function refuteWinnerCallback(
        address checkedAddress,
        uint256 balance
    ) external confidential afterAuctionTime onlyOracle returns (bytes memory) {
        if (balance > winningBid) {
            return
                abi.encodeWithSelector(
                    this.overrideWinner.selector,
                    checkedAddress,
                    balance
                );
        }
        emit WinnerAddress(auctionWinnerL1);
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    function overrideWinner(
        address newWinner,
        uint256 newWinningBalance
    ) public emitOffchainLogs {
        emit WinnerAddress(newWinner);
        auctionWinnerL1 = newWinner;
        winningBid = newWinningBalance;
    }

    function updateWinner(address winnerL1,address winnerSuave, uint256 _winningBid) public emitOffchainLogs {
        auctionWinnerL1 = winnerL1;
        auctionWinnerSuave = winnerSuave;
        winningBid = _winningBid;
    }

    // simple callback to publish offchain events
    function onchainCallback() public emitOffchainLogs {}

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

    //TODO: remove ; only for testing
    function startAuctionTest() public returns (bytes memory) {
        return registerContractAtServer();
    }

    // Why doesnt the frontend call our server with the cronjob?
    function startAuction()
        public
        onlyAuctioneer
        auctionNotStarted
        validAuctionEndTime
        returns (bytes memory)
    {
        Oracle oracleRPC = Oracle(oracle);
        return oracleRPC.getNFTOwnedBy(nftContract, tokenId);
    }

    function confirmNFTowner(
        address NFTowner
    ) external onlyOracle returns (bytes memory) {
        require(
            NFTowner == nftHoldingAddress,
            "The NFT was not transferred yet"
        );
        return registerContractAtServer();
    }

    function registerContractAtServer() public returns (bytes memory) {
        Oracle oracleRPC = Oracle(oracle);
        return oracleRPC.registerContract(address(this), auctionEndTime);
    }

    function finaliseStartAuction() external view onlyOracle returns (bytes memory) {
        return abi.encodeWithSelector(this.startAuctionCallback.selector);
    }

    // BIDDING RELATED FUNCTIONALITY ---------------------------------------------------------------------------------------------------------------------------------
    event RevealBiddingAddress(address bidderL1);
    event NFTHoldingAddressEvent(address nftHoldingAddress);
    event WinnerAddress(address winner);
    event EncBiddingAddress(address owner, bytes encryptedL1Address);

    string public PRIVATE_KEYS = "KEY";

    // mapping of public SUAVE addresses to 1. private keys of their bidding address on L1 and 2. the L1 return address for their bids
    mapping(address => Suave.DataId) privateKeysL1;
    //mapping(address => Suave.DataId) bidReturnAddressesL1;
    mapping(address => bool) _addressHasBid;
    // keep track of the bidders
    uint256 public bidderAmount = 0;
    mapping(uint256 => address) bidderAddresses;

    modifier addressHasBid(address owner) {
        require(
            _addressHasBid[owner],
            string.concat("No bidding address related to this sender:", toHexString(abi.encodePacked(owner)))
        );
        _;
    }
        modifier senderHasBid {
        require(
            _addressHasBid[msg.sender],
            string.concat("No bidding address related to msg.sender:", toHexString(abi.encodePacked(msg.sender)))
        );
        _;
    }

    modifier addressWithoutBid(address owner) {
        require(
            _addressHasBid[owner] == false,
            "Address already owns bidding address."
        );
        _;
    }

    // TODO how to make sure callbacks are only called by the responding offchain functions
    function updatePrivateKeyCallback(
        address owner,
        Suave.DataId keyRecord
    ) public emitOffchainLogs {
        privateKeysL1[owner] = keyRecord;
        _addressHasBid[owner] = true;
        bidderAddresses[bidderAmount++] = owner;
    }

    // emits the bidding address in a encrypted fashion, creates a new one if user has no bidding address so far
    function getBiddingAddress() public confidential returns (bytes memory) {
        bytes memory randomKey = Context.confidentialInputs();
        if (_addressHasBid[msg.sender] == false) {
            string memory privateKey = Suave.privateKeyGen(
                Suave.CryptoSignature.SECP256
            );
            bytes memory keyData = bytes(privateKey);

            address[] memory peekers = new address[](2);
            peekers[0] = address(this);
            peekers[1] = oracle; // oracle can also see private keys
            Suave.DataRecord memory record = Suave.newDataRecord(
                0,
                peekers,
                peekers,
                PRIVATE_KEYS
            );
            Suave.confidentialStore(record.id, PRIVATE_KEYS, keyData);

            address publicL1Address = Secp256k1.deriveAddress(privateKey);
            bytes memory encrypted = Suave.aesEncrypt(randomKey, abi.encodePacked(publicL1Address));
            emit EncBiddingAddress(
                msg.sender,
                encrypted
            );
            return
                abi.encodeWithSelector(
                    this.updatePrivateKeyCallback.selector,
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
            bytes memory encrypted = Suave.aesEncrypt(randomKey, abi.encodePacked(publicL1Address));
            emit EncBiddingAddress(
                msg.sender,
                encrypted
            );

            return abi.encodeWithSelector(this.onchainCallback.selector);
        }
    }

    // TODO replace with proper (AES) encryption precompile
    function encryptForAddress(
        address suaveAddress,
        address biddingAddress
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(biddingAddress);
    }

    // END-AUCTION RELATED FUNCTIONALITY -----------------------------------------------------------------------------------------------------------------------------
    function revealBidders()
        public
        confidential
        afterAuctionTime
        returns (bytes memory)
    {
        for (uint256 i = 0; i < bidderAmount; i++) {
            bytes memory privateL1Key = Suave.confidentialRetrieve(
                privateKeysL1[bidderAddresses[i]],
                PRIVATE_KEYS
            );
            address publicL1Address = Secp256k1.deriveAddress(
                string(privateL1Key)
            );
            emit RevealBiddingAddress(publicL1Address);
        }
        if(finalBlockNumber != 0){ // revealBidders should not override finalBlock
            return abi.encodeWithSelector(this.onchainCallback.selector);
        } else  //TODO: test this
        return getEthBlockNumber();
    }

    //only the auctioneer can claim the winning bid
    function claimWinningBid(
        address returnAddressL1
    )
        external
        afterAuctionTime
        confidential
        winnerRegistered()
        onlyAuctioneer()
        returns (bytes memory)
    {
            Oracle oracleRPC = Oracle(oracle);
            return
                        oracleRPC.transfer(
                            returnAddressL1,
                            finalBlockNumber,
                            privateKeysL1[auctionWinnerSuave]
                        );
            return abi.encodeWithSelector(this.onchainCallback.selector); // This should not be called
    }

    // msg.sender is suaveBidder and returnAddressL1 is on L1 chain
    function refundBid(
        address returnAddressL1
    )
        external
        afterAuctionTime
        senderHasBid
        confidential
        notWinnerSuave()
        returns (bytes memory)
    {
         Oracle oracleRPC = Oracle(oracle);
        return
            oracleRPC.transfer(
                returnAddressL1,
                finalBlockNumber,
                privateKeysL1[msg.sender]
            ); 
           // return abi.encodeWithSelector(this.onchainCallback.selector); // This should not be called
    } 
    
    function refundNFT() auctionStarted internal {
        // TODO transfer back to auctioneerL1
    }

    function transferNFT(address winner) isWinnerSuave() public {
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
