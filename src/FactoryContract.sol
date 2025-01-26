// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

import "suave-std/Suapp.sol";
import "./SealedAuction.sol";
import "suave-std/Context.sol";
import "./utils/Utils.sol";

interface IContract {
    function test() external;
}

contract FactoryContract is Suapp {
    Suave.DataId signingKeyRecord;
    string private constant PRIVATE_KEY = "KEY";
    string private constant OWNER = "OWNER";
    string private constant AUCTION_CONTRACTS = "AUCTION_CONTRACTS";
    address[] deployedContracts;
    //uint256 deployedContractsCount = 0;

    event AuctionContractCreated(
        address indexed contractAddress,
        address indexed owner
    );

    function onchainCallback() public emitOffchainLogs {}

    function updateKeyOnchain(
        Suave.DataId _signingKeyRecord
    ) public emitOffchainLogs {
        signingKeyRecord = _signingKeyRecord;
    }

    /*
     *   Register private key via confidential input
     *
     */
    function registerPrivateKeyOffchain() public returns (bytes memory) {
        bytes memory keyData = Context.confidentialInputs();
        address[] memory peekers = new address[](1);
        peekers[0] = address(this);

        Suave.DataRecord memory record = Suave.newDataRecord(
            0,
            peekers,
            peekers,
            "private_key"
        );
        Suave.confidentialStore(record.id, PRIVATE_KEY, keyData);
        Suave.confidentialStore(record.id, OWNER, abi.encode(msg.sender));
        return
            abi.encodeWithSelector(this.updateKeyOnchain.selector, record.id);
    }

    // unused so far TODO: which use-cases?
    modifier onlyOwner() {
        require(
            Utils.isEqual(
                Suave.confidentialRetrieve(signingKeyRecord, OWNER),
                abi.encode(msg.sender)
            ),
            "Only the owner of the Factory Contract is allowed to do that"
        );
        _;
    }

    function onchainCreateContract(bytes memory ac) public emitOffchainLogs {
        address ad = (abi.decode(ac, (address)));
        insertAuctionContract(ad);
    }

    /*
     * stores the address of a newly created AuctionContract in deployedContracts
     * emits AuctionContractCreated Event
     */
    function createAuctionContractOffchain() public returns (bytes memory) {
        SealedAuction newContract = new SealedAuction(
            address(0),
            0,
            0,
            0,
            address(0)
        );
        /*         Suave.confidentialStore(
            signingKeyRecord,
            AUCTION_CONTRACTS,
            abi.encode(address(newContract))
        ); */
        emit AuctionContractCreated(address(newContract), msg.sender);
        return
            abi.encodeWithSelector(
                this.onchainCreateContract.selector,
                abi.encode(address(newContract))
            );
    }

    /*
     * returns the list of deployed auction contracts
     * TODO: unfinished/untested
     */
    function getDeployedContracts()
        public
        onlyOwner
        returns (address[] memory)
    {
        return deployedContracts;
    }

    //offchain
    function test() public returns (bytes memory) {
        return abi.encodeWithSelector(this.testOnchain.selector);
    }

    /*
     * TODO: ic.test() call is not working so far; How to call deployed contracts?
     */
    function testOnchain() public emitOffchainLogs {
        require(
            deployedContracts.length > 0,
            "No deployed contracts available"
        );
        // emit HelperEvent3(deployedContracts[0]);
        IContract ic = IContract(deployedContracts[0]);
        ic.test();
    }

    /*
     * internel function to append AuctionContract
     */
    function insertAuctionContract(address newContract) private {
        deployedContracts.push(newContract);
    }
}
