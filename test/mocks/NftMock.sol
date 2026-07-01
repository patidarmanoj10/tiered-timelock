// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

contract Erc721Mock is ERC721 {
    constructor() ERC721("MockNFT", "MNFT") {}

    function mint(address to_, uint256 id_) external {
        _mint(to_, id_);
    }
}

contract Erc1155Mock is ERC1155 {
    constructor() ERC1155("") {}

    function mint(address to_, uint256 id_, uint256 amount_) external {
        _mint(to_, id_, amount_, "");
    }

    function mintBatch(address to_, uint256[] memory ids_, uint256[] memory amounts_) external {
        _mintBatch(to_, ids_, amounts_, "");
    }
}
