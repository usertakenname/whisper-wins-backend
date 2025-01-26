// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

abstract contract TestApes is ERC721Enumerable, Ownable {
    uint256 public constant MAX_APES = 420;
    uint256 private _currentTokenId = 1;

    mapping(uint256 => string) _testApesURIs;

    constructor() ERC721("TestApesAtTUM", "TAT") {}

    function mintApe(address to) public onlyOwner {
        require(_currentTokenId <= MAX_APES, "All Apes have been minted");
        uint256 tokenId = _currentTokenId;

        _safeMint(to, tokenId);

        _currentTokenId++;
    }

    function tokenURI(
        uint256 tokenId
    ) public view override returns (string memory) {
        require(tokenId != 0, "Theres no 0-id");
        require(tokenId <= _currentTokenId, "Token ID does not exist");
        return _testApesURIs[tokenId];
    }

    function setTokenURI(
        uint256 tokenId,
        string memory newURI
    ) public onlyOwner {
        require(tokenId != 0, "Theres no 0-id");
        require(tokenId <= _currentTokenId, "Token ID does not exist");
        _testApesURIs[tokenId] = newURI;
    }
}
