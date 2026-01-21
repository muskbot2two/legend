// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../openzeppelin-contracts/access/Ownable.sol";
import "../openzeppelin-contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "../openzeppelin-contracts/token/ERC20/IERC20.sol";
import "../openzeppelin-contracts/utils/Strings.sol";

interface IDao {
    function inviterOf(address user) external view returns (address);
}

contract NFT is ERC721Enumerable, Ownable {
    using Strings for uint256;

    uint public totalDividend;//bnb
    uint public accRewardPerShare;
    mapping(uint => uint) public claimedRewardsById;

    uint public totalDividendToken;
    uint public accRewardPerShareToken;
    mapping(uint => uint) public claimedRewardsByIdToken;
    mapping(address => uint) public claimedBNB;
    mapping(address => uint) public claimedToken;
    mapping(address => uint) public teamNum;

    uint public maxSupply = 1000;
    uint public payment = 5 * 1e17;

    address public LEG;
    address public DAO;
    address public vault = 0xc61061BD1072afd8809aD17670E81f322afA6470;

    string public baseURI = "ipfs://bafkreifz2eoffauvrkut5o5d2qjg3ufenlyhznpsm32wj3fyk5t5naksya/";
    constructor() ERC721("LEG NFT", "LEGNFT") Ownable(msg.sender) {}

    receive() external payable {
        if (msg.sender == LEG) {
            uint bnbAmount = msg.value;
            uint num = totalSupply();
            if (num > 0) {
                accRewardPerShare += bnbAmount / num;
                totalDividend += bnbAmount;
            }  
        }
    }

    function init(address token, address dao) external onlyOwner {
        require(token != address(0), "ZERO");
        require(dao != address(0), "ZERO");
        LEG = token;
        DAO = dao;
    }

    function deflationIn(uint tokenAmount) external {
        require(msg.sender == LEG);
        uint num = totalSupply();
        if (num > 0) {
            accRewardPerShareToken += tokenAmount / num;
            totalDividendToken += tokenAmount;
        }  
    }

    function setVault(address _vault) public onlyOwner {
        require(_vault != address(0), "ZERO");
        vault = _vault;
    }

    function setPayment(uint _payment) public onlyOwner {
        payment = _payment;
    }

    function _baseURI() internal view virtual override returns (string memory) {
        return baseURI;
    }

    function tokenURI(uint256 tokenId)
        public
        view
        virtual
        override
        returns (string memory)
    {
        _requireOwned(tokenId);
        return baseURI;
    }

    function buy() external payable {
        address inviter = IDao(DAO).inviterOf(msg.sender);
        require(inviter != address(0), "no inviter");
        require(msg.value == payment);
        require(totalSupply() < maxSupply);
        (bool success,) = address(vault).call{value: payment}("");
        require(success);

        uint newTokenId = totalSupply() + 1;
        claimedRewardsById[newTokenId] = accRewardPerShare;
        claimedRewardsByIdToken[newTokenId] = accRewardPerShareToken;
        _safeMint(msg.sender, newTokenId);

        address _inviter = inviter;
        for (uint8 i; i < 80; i++) {
            if (_inviter == address(0)) break;
            teamNum[_inviter]++;

            _inviter = IDao(DAO).inviterOf(_inviter);
        }
    }

    function pendingReward(address user) public view returns (uint, uint) {
        uint balance = balanceOf(user);
        if (balance == 0) return (0, 0);
        uint pending;
        uint pendingToken;
        for (uint i; i < balance; i++) {
            uint id = tokenOfOwnerByIndex(user, i);
            pending += (accRewardPerShare - claimedRewardsById[id]);
            pendingToken += (accRewardPerShareToken - claimedRewardsByIdToken[id]);
        }
        return (pending, pendingToken);
    }

    function claim() external {
        _claim(msg.sender);
    }

    function _claim(address user) private {
        uint balance = balanceOf(user);
        if (balance == 0) return;

        uint pending;
        uint pendingToken;
        for (uint i; i < balance; i++) {
            uint id = tokenOfOwnerByIndex(user, i);
            pending += (accRewardPerShare - claimedRewardsById[id]);
            claimedRewardsById[id] = accRewardPerShare;

            pendingToken += (accRewardPerShareToken - claimedRewardsByIdToken[id]);
            claimedRewardsByIdToken[id] = accRewardPerShareToken;
        }

        if (pending > 0) {
            (bool success,) = address(user).call{value: pending}("");
            require(success);
            claimedBNB[user] += pending;
        }

        if (pendingToken > 0) {
            IERC20(LEG).transfer(user, pendingToken);
            claimedToken[user] += pendingToken;
        }
    }

    function rescueETH(address to, uint amount) external onlyOwner {
        (bool success,) = address(to).call{value: amount}("");
        require(success);
    }

    function rescueERC20(address token, address to, uint amount) external onlyOwner {
        IERC20(token).transfer(to, amount);
    }
}
