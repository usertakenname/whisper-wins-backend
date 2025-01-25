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

interface OracleRollup {
    function getEthBlockNumber() external returns (bytes memory);
    function getNFTOwnedBy(
        address _nftContract,
        uint256 _tokenId
    ) external returns (bytes memory);
    function transferETH(
        address returnAddress,
        Suave.DataId suaveDataID
    ) external returns (bytes memory);
    function transferNFT(
        address from,
        address to,
        address nftContract,
        uint256 tokenId,
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

contract SealedAuctionRollup is Suapp {
    address public auctioneerSUAVE; // TODO: which fields should be public? this SUAVE address is public anyways as it is the call deploying the contract
    address public auctionWinnerL1 = address(0);
    uint256 public winningBid = 0;
    address public auctionWinnerSuave = address(0); // no need to have this public i'd say
    address public oracle; // TODO: hardcode to static address once we've deployed the final version
    address nftHoldingAddress;
    //address(0x929e17E4B2085130a415C5f69Cfb1Fbef163bDAd); //test Address
    address public nftContract;
    uint256 public tokenId;
    uint256 public auctionEndTime;
    uint256 public minimalBid;
    uint256 public finalBlockNumber; // on ETH Chain
    bool public auctionHasStarted = false;
    address public trustedCentralParty = address(0); // possibility to scale the winner-selection by using a external service (TTP) => its address needs to be defined here

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

    modifier inBackOutTime() {
        require(auctionHasStarted, "Auction not yet started");
        uint256 until = auctionEndTime - 5 * 60;
        require(
            block.timestamp <= until,
            string.concat(
                "Auction ending too soon! Current timestamp: ",
                toString(block.timestamp),
                " > back out until timestamp: ",
                toString(until)
            )
        );
        _;
    }

    // TODO: add afterChallengePeriod to allow claiming of bids and NFT
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
                " > auction ending timestamp: ",
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

    modifier isTrustedCentralParty(address addr) {
        require(
            trustedCentralParty == addr,
            "Only the central party can call this functionality"
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
        // TODO: delete this?
        // bytes memory privateL1Key = Suave.confidentialRetrieve(
        //     privateKeysL1[checkAddress],
        //     PRIVATE_KEYS
        // );
        // address publicL1Address = Secp256k1.deriveAddress(string(privateL1Key));
        // return publicL1Address == auctionWinnerL1;
        return checkSuaveAddress == auctionWinnerSuave;
    }

    // simple callback to publish offchain events
    function onchainCallback() public emitOffchainLogs {}

    // TODOL: wieso brauchen wir diese funktion? => get closest block to endTimestamp instead of the block when reveal is called
    function getEthBlockNumber() private returns (bytes memory) {
        OracleRollup oracleRPC = OracleRollup(oracle);
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

    // SETUP AUCTION RELATED FUNCTIONALITY ---------------------------------------------------------------------------------------------------------------------------
    event NFTHoldingAddressEvent(address nftHoldingAddress);

    // this function generates (if not yet done) the nftHoldingAddres for the auction and emits it
    // TODOL: confidential modifier needed? generelly at every place without conf input necessary
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
                    this.createNFTAddressCallback.selector,
                    _nftHoldingAddress,
                    record.id
                );
        }
        emit NFTHoldingAddressEvent(nftHoldingAddress);
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    function createNFTAddressCallback(
        address _nftHoldingAddress,
        Suave.DataId keyRecord
    ) public {
        nftHoldingAddress = _nftHoldingAddress;
        privateKeysL1[address(this)] = keyRecord; // The lookup address for the NFT-holding-address key is the auction contracts address
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

    //TODO: remove ; only for testing
    function startAuctionTest() public returns (bytes memory) {
        return registerContractAtValidator();
    }

    // Why doesnt the frontend call our server with the cronjob?
    // bc our contract should be independent of the frontend
    function startAuction()
        public
        onlyAuctioneer
        auctionNotStarted
        validAuctionEndTime
        returns (bytes memory)
    {
        OracleRollup oracleRPC = OracleRollup(oracle);
        return oracleRPC.getNFTOwnedBy(nftContract, tokenId);
    }

    function confirmNFTowner(
        address NFTowner
    ) external onlyOracle returns (bytes memory) {
        require(
            NFTowner == nftHoldingAddress,
            "The NFT was not transferred yet"
        );
        return registerContractAtValidator();
    }

    function registerContractAtValidator() public returns (bytes memory) {
        OracleRollup oracleRPC = OracleRollup(oracle);
        return oracleRPC.registerContract(address(this), auctionEndTime);
    }

    function finaliseStartAuction()
        external
        view
        onlyOracle
        returns (bytes memory)
    {
        return abi.encodeWithSelector(this.startAuctionCallback.selector);
    }

    // BIDDING RELATED FUNCTIONALITY ---------------------------------------------------------------------------------------------------------------------------------
    event EncBiddingAddress(address owner, bytes encryptedL1Address);

    string public PRIVATE_KEYS = "KEY";

    // mapping of public SUAVE addresses to private keys of their bidding address on L1
    mapping(address => Suave.DataId) privateKeysL1;
    mapping(address => bool) _addressHasBid;
    // keep track of the bidders: bidderAmount and mapping from i-th bidder to its SUAVE-address
    uint256 public bidderAmount = 0;
    mapping(uint256 => address) bidderSuaveAddresses;
    // store all L1 bidding addresses once revealed
    address[] publicL1Addresses = new address[](0);

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
        bidderSuaveAddresses[bidderAmount++] = owner;
    }

    // If caller has no bidding address so far, create a new bidding address and/else emit it in an encrypted fashion (secret is provided in confidential Input)
    function getBiddingAddress() public confidential returns (bytes memory) {
        bytes memory secretKey = Context.confidentialInputs();
        require(secretKey.length == 32, "Please provide a valid AES-256 key");
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
            bytes memory encrypted = Suave.aesEncrypt(
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
            bytes memory encrypted = Suave.aesEncrypt(
                secretKey,
                abi.encodePacked(publicL1Address)
            );
            emit EncBiddingAddress(msg.sender, encrypted);
            return abi.encodeWithSelector(this.onchainCallback.selector);
        }
    }

    // END-AUCTION RELATED FUNCTIONALITY -----------------------------------------------------------------------------------------------------------------------------
    event RevealBiddingAddresses(address[] bidderL1);
    event WinnerAddress(address winner);

    function revealBiddersCallback(
        address[] memory l1Addresses
    ) public emitOffchainLogs {
        publicL1Addresses = l1Addresses;
    }

    function revealBidders()
        public
        confidential
        afterAuctionTime
        returns (bytes memory)
    {
        if (publicL1Addresses.length == 0 && bidderAmount > 0) {
            address[] memory l1Addresses = new address[](bidderAmount);
            for (uint256 i = 0; i < bidderAmount; i++) {
                bytes memory privateL1Key = Suave.confidentialRetrieve(
                    privateKeysL1[bidderSuaveAddresses[i]],
                    PRIVATE_KEYS
                );
                address publicL1Address = Secp256k1.deriveAddress(
                    string(privateL1Key)
                );
                l1Addresses[i] = publicL1Address;
            }
            emit RevealBiddingAddresses(l1Addresses);
            return
                abi.encodeWithSelector(
                    this.revealBiddersCallback.selector,
                    l1Addresses
                );
        }
        emit RevealBiddingAddresses(publicL1Addresses);
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    // Idea is that anyone can claim themselves as the winner and the contract checks the balance of the account at the time the auction has ended (by final block number)
    // Have a validator monitor the revealed addresses and call this method with the winner
    // TODOL: this works on SUAVE-addressToCheck? ==> how does anyone know the suave address to a related and revealed L1 address?
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
        OracleRollup oracleRPC = OracleRollup(oracle);
        return
            oracleRPC.getBalanceAtBlockExternal(
                publicL1Address,
                finalBlockNumber
            );
    }

    // Simplification: In order to deal with two or more people bidding the winning amount, we use "first-come, first-serve" to break the tie in favor of the first proposed address.
    // In general, a re-auction or a new round of bidding between the potential winners would be a more fair but more complex solution.
    function refuteWinnerCallback(
        address checkedAddress,
        uint256 balance
    ) external confidential afterAuctionTime onlyOracle returns (bytes memory) {
        if (balance < winningBid) {
            revert(
                "Proposed winner address has less funds than the current winner"
            );
        } else if (balance == winningBid && checkedAddress != auctionWinnerL1) {
            revert(
                'Tie occurred! Our tie-breaking rule is "first-come, first-served". Unfortunately, the other bidder with the same bidding amount already registered as the winner.'
            );
        }
        return
            abi.encodeWithSelector(
                this.overrideWinner.selector,
                checkedAddress,
                balance
            );
    }

    function overrideWinner(
        address newWinner,
        uint256 newWinningBalance
    ) public emitOffchainLogs {
        emit WinnerAddress(newWinner);
        auctionWinnerL1 = newWinner;
        winningBid = newWinningBalance;
    }

    //######################################################
    // Possible simplification: only one trusted central entity can register a winner which is final (no optimistic rollup with a challenge period)
    // addressToCheck is L1 Address
    function registerWinner(
        address addressToCheckL1,
        uint256 _winningBid
    )
        public
        confidential
        isTrustedCentralParty(msg.sender)
        afterAuctionTime
        returns (bytes memory)
    {
        for (uint256 i = 0; i < bidderAmount; i++) {
            bytes memory privateL1Key = Suave.confidentialRetrieve(
                privateKeysL1[bidderSuaveAddresses[i]],
                PRIVATE_KEYS
            );
            address publicL1Address = Secp256k1.deriveAddress(
                string(privateL1Key)
            );
            if (publicL1Address == addressToCheckL1) {
                return
                    abi.encodeWithSelector(
                        this.updateWinner.selector,
                        publicL1Address,
                        bidderSuaveAddresses[i],
                        _winningBid
                    );
            }
        }
        revert(
            string.concat(
                "Proposed winner L1 address not part of the auction: ",
                toHexString(abi.encodePacked(addressToCheckL1))
            )
        );
    }

    function updateWinner(
        address winnerL1,
        address winnerSuave,
        uint256 _winningBid
    ) public emitOffchainLogs {
        auctionWinnerL1 = winnerL1;
        auctionWinnerSuave = winnerSuave;
        winningBid = _winningBid;
    }
    //######################################################

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
        OracleRollup oracleRPC = OracleRollup(oracle);
        return
            oracleRPC.transferETH(
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
        returns (bytes memory)
    {
        OracleRollup oracleRPC = OracleRollup(oracle);
        return
            oracleRPC.transferETH(returnAddressL1, privateKeysL1[msg.sender]);
    }

    function claimNFT(
        address returnAddressL1
    )
        public
        confidential
        isWinnerSuave
        afterAuctionTime
        returns (bytes memory)
    {
        OracleRollup oracleRPC = OracleRollup(oracle);
        return
            oracleRPC.transferNFT(
                nftHoldingAddress,
                returnAddressL1,
                nftContract,
                tokenId,
                privateKeysL1[address(this)]
            );
    }

    // BACK-OUT FUNCTIONALITY ----------------------------------------------------------------------------------------------------------------------------------------
    // before the auction is started, the auctioneer has the option to claim the NFT back
    function refundNFT(
        address returnAddressL1
    )
        public
        confidential
        onlyAuctioneer
        auctionNotStarted
        returns (bytes memory)
    {
        OracleRollup oracleRPC = OracleRollup(oracle);
        return
            oracleRPC.transferNFT(
                nftHoldingAddress,
                returnAddressL1,
                nftContract,
                tokenId,
                privateKeysL1[address(this)]
            );
    }

    // until 5min before the auction ends, a bidder is allowed to back out and reclaim the bid
    function backOutBid(
        address returnAddressL1
    ) external confidential senderHasBid inBackOutTime returns (bytes memory) {
        OracleRollup oracleRPC = OracleRollup(oracle);
        return
            oracleRPC.transferETH(returnAddressL1, privateKeysL1[msg.sender]);
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
