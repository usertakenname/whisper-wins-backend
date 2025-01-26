//Contract based on https://docs.openzeppelin.com/contracts/3.x/erc721
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

abstract contract PrettyExpensiveClub is ERC721, Ownable {
    uint256 private _tokenIds = 0;
    mapping(uint256 => string) private _tokenURIs;
    string private _baseURIPCE;

    uint256 MAX_PER_TX = 50;
    uint256 BASE_PRICE = 1000000000000000; // 0.001 ETH
    uint256 MAX_SUPPLY = 420420420420420420420;

    constructor(string memory baseURI) ERC721("PrettyExpensiveClub", "PEC") {
        _baseURIPCE = baseURI;
    }

    function mintNFT(
        address recipient,
        string memory tokenURI
    ) public onlyOwner returns (uint256) {
        uint256 newItemId = _tokenIds++;
        _mint(recipient, newItemId);
        if (bytes(tokenURI).length > 0) {
            _tokenURIs[newItemId] = tokenURI;
        }
        return newItemId;
    }

    function mintNFTs(address recipient, uint256 amount) public onlyOwner {
        require(amount <= MAX_PER_TX, "Can't mint more than 50 at once...");
        for (uint256 i = 0; i < amount; i++) {
            _mint(recipient, _tokenIds++);
        }
    }

    function buyNFTs(uint256 amount) public payable {
        require(
            msg.value >= amount * BASE_PRICE,
            "Not enough funds to aquire that many PECs..."
        );
        for (uint256 i = 0; i < amount; i++) {
            _mint(msg.sender, _tokenIds++);
        }
    }

    function setTokenURIAfterwards(
        uint256 itemId,
        string memory tokenURI
    ) public onlyOwner {
        _tokenURIs[itemId] = tokenURI;
    }

    function setBaseURI(string memory baseURI) public onlyOwner {
        _baseURIPCE = baseURI;
    }

    function withdraw() public onlyOwner {
        uint256 balance = address(this).balance;
        payable(msg.sender).transfer(balance);
    }
}
