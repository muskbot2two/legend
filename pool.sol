// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        this; // silence state mutability warning without generating bytecode - see https://github.com/ethereum/solidity/issues/2691
        return msg.data;
    }
}

contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor () {
        address msgSender = _msgSender();
        _owner = msgSender;
        emit OwnershipTransferred(address(0), msgSender);
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(_owner == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

interface IERC20 {
    function totalSupply() external view returns (uint);
    function balanceOf(address account) external view returns (uint);
    function transfer(address recipient, uint amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint);
    function approve(address spender, uint amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint amount) external returns (bool);
}

interface IRouter {
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
}

interface IDao {
    function start(uint startTime) external;
    function stakeIn(address user, uint bnbAmount) external payable;
}

interface INft {
    function balanceOf(address owner) external view returns (uint256);
}

contract Pool is Ownable {
    struct UserInfo {
        uint bnbIn;
        uint lpAmount;
        uint weight;
        uint rewards;
        uint debt;
        uint claimed;
    }
    mapping (address => UserInfo) public userInfo;
    mapping (address => bool) public whitelist;

    address public ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address public WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public vault = 0x5489Ffc1816FFF4d8d239A19Ad5D65805ca868d4;
    address public LEG;
    address public PAIR;
    address public DAO;
    address public NFT;

    uint public startTime;
    uint public totalDividend;
    uint public accRewardPerShare;
    uint public totalWeight;
    uint public minAmount = 1e17;
    uint public maxRatio = 10; // 0.1%
    bool public publicStake = false;

    struct ItemInfo {
        address account;
        uint amount;//参与金额
        uint time; //时间
        uint blockNum;//区块高度
        uint status; // 0 开奖中， 1 末中奖， 2 已中奖
        bytes32 nextBlockHash;
    }
    mapping (uint => ItemInfo) public itemInfoByIndex;
    mapping(address => uint[]) public indexesOf;

    uint public totalItemNum;
    uint public lastProcessItemIndex;
    uint public rewardRatio = 190;
    uint public hashBalance;//hash池余额
    uint public liquifyBalace;
    uint public maxIn = 10000 * 1e18;
    uint public minBalanceToLiquify = 10000 * 1e18;
    uint public slippage = 5;

    uint public vaultFund;
    uint public lastInTime;
    address[] public buyers;
    uint256 private constant MAX_BUYERS = 10;
    mapping(address => uint256) private addressToIndex; // 1-based index (0表示不存在)

 
    function INIT(address _leg, address _pair, address _dao, address _nft) external onlyOwner {
        require(_leg != address(0), "ZERO");
        require(_pair != address(0), "ZERO");
        require(_dao != address(0), "ZERO");
        require(_nft != address(0), "ZERO");
        LEG = _leg;
        PAIR = _pair;
        DAO = _dao;
        NFT = _nft;
        IERC20(LEG).approve(ROUTER, type(uint).max);
        IERC20(WBNB).approve(ROUTER, type(uint).max);
    }

    function start(uint _startTime) external onlyOwner {
        startTime = _startTime;
        IDao(DAO).start(_startTime);
    }

    function setMinAndMax(uint _minAmount, uint _maxRatio) external onlyOwner {
        minAmount = _minAmount;
        maxRatio = _maxRatio;
    }

    function setMulitWhitelist(address[] calldata accounts, bool value) public onlyOwner {
        for(uint8 i = 0; i < accounts.length; i++) {
            whitelist[accounts[i]] = value;
        }
    }

    function setRewardRatio(uint _rewardRatio) public onlyOwner {
        rewardRatio = _rewardRatio;
    }

    function setPublicStake(bool _publicStake) external onlyOwner {
        publicStake = _publicStake;
    }

    function setMaxIn(uint _maxIn) external onlyOwner {
        maxIn = _maxIn;
    }

    function setSlippage(uint _slippage) external onlyOwner {
        slippage = _slippage;
    }

    function setMinBalanceToLiquify(uint _minBalanceToLiquify) external onlyOwner {
        minBalanceToLiquify = _minBalanceToLiquify;
    }

    function getPassedDays() public view returns (uint) {
        return (block.timestamp - startTime) / 1 days;
    }

    function deflationIn(uint tokenAmount) external {
        require(msg.sender == LEG);
        uint amountToMiner = tokenAmount * 80 / 85;
        if (totalWeight > 0) {
            accRewardPerShare += amountToMiner * 1e18 / totalWeight;
            totalDividend += amountToMiner;
        }
        uint amountToHash = tokenAmount * 5 / 85;
        hashBalance += amountToHash;
    }

    function stakeInBy(address user) external payable {
        require(msg.sender == LEG, "not valide caller");
        _stakeIn(user, msg.value);
    }

    function stakeIn() external payable {
        _stakeIn(msg.sender, msg.value);
    }

    function _stakeIn(address user, uint bnbAmount) private {
        require(startTime > 0, "not time");
        if (!publicStake) {
            require(INft(NFT).balanceOf(user) > 0 || whitelist[user], "not whitelist");
        }
        require(bnbAmount >= minAmount, "min");
        UserInfo storage ui = userInfo[user];
        ui.bnbIn += bnbAmount;
        require(ui.bnbIn <= IERC20(WBNB).balanceOf(PAIR) * maxRatio / 10000, "max");
        
        //bnb分配
        _processVaultFund(user, bnbAmount * 3 / 100);

        uint bToVault = bnbAmount * 5 / 100;
        (bool success,) = address(vault).call{value: bToVault}("");
        require(success);

        uint lpAmount = IERC20(PAIR).balanceOf(user);
        _addLiquidity(user, bnbAmount * 60 / 100);
        lpAmount = IERC20(PAIR).balanceOf(user) - lpAmount;

        ui.lpAmount += lpAmount;
        _updateRewards(user);
        uint passedDay = getPassedDays();
        uint weight = lpAmount * (passedDay * 150 + 10000) / 10000;
        ui.weight += weight;
        ui.debt = ui.weight * accRewardPerShare / 1e18;
        totalWeight += weight;

        uint toDao = bnbAmount * 32 / 100;
        IDao(DAO).stakeIn{value: toDao}(user, bnbAmount);
    }

    function _processVaultFund(address user, uint bnbAmount) private {
        if (lastInTime != 0 && block.timestamp - lastInTime >= 3 days) {
            uint len = buyers.length;
            if (len == 0) return;
            uint reward = vaultFund / len;
            for (uint8 i = 0; i < len; i++) {
                address cur = buyers[i];
                if (cur != address(0)) {
                    (bool success,) = address(cur).call{value: reward}("");
                    require(success);
                }
            }
            vaultFund = 0;
        }
        // 如果地址已存在，需要从原位置移除
        if (addressToIndex[user] > 0) {
            _removeExistingBuyer(user);
        }
        
        // 如果数组已满，移除最后一个（最旧的）
        if (buyers.length == MAX_BUYERS) {
            address oldestBuyer = buyers[MAX_BUYERS - 1];
            delete addressToIndex[oldestBuyer];
            buyers.pop();
        }
        
        buyers.push(user);
        
        // 将所有元素向后移动一位
        for (uint256 i = buyers.length - 1; i > 0; i--) {
            buyers[i] = buyers[i - 1];
            addressToIndex[buyers[i]] = i + 1; // 更新索引
        }
        
        // 设置新地址到开头
        buyers[0] = user;
        addressToIndex[user] = 1; // 1-based index

        lastInTime = block.timestamp;
        vaultFund += bnbAmount;
    }

     function _removeExistingBuyer(address buyer) private {
        uint256 index = addressToIndex[buyer] - 1; // 转换为0-based index
        
        // 将后面的元素向前移动
        for (uint256 i = index; i < buyers.length - 1; i++) {
            buyers[i] = buyers[i + 1];
            addressToIndex[buyers[i]] = i + 1; // 更新索引
        }
        
        // 移除最后一个元素
        buyers.pop();
        delete addressToIndex[buyer];
    }

    function _updateRewards(address user) private {
        UserInfo storage ui = userInfo[user];
        ui.rewards = pendingRewards(user);
        ui.debt = ui.weight * accRewardPerShare / 1e18;
    }

    function pendingRewards(address user) public view returns (uint) {
        UserInfo storage ui = userInfo[user];
        return ui.rewards + ui.weight * accRewardPerShare / 1e18 - ui.debt;
    }

    function _addLiquidity(address user, uint256 bnbAmount) private {
        uint half = bnbAmount / 2;
        uint tokenAmount = IERC20(LEG).balanceOf(address(this));
        swapEthForTokens(half, address(this));
        tokenAmount = IERC20(LEG).balanceOf(address(this)) - tokenAmount;

        IRouter(ROUTER).addLiquidityETH{value: half}(
            LEG,
            tokenAmount,
            0,
            0,
            user,
            block.timestamp
        );
    }

    function swapEthForTokens(uint256 amountIn, address to) private {
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = LEG;

        uint[] memory amountOuts = IRouter(ROUTER).getAmountsOut(amountIn, path);
        uint min = amountOuts[1] * (100 - slippage) / 100;
        IRouter(ROUTER).swapExactETHForTokensSupportingFeeOnTransferTokens{value: amountIn}(
            min,
            path,
            to,
            block.timestamp
        );

    }
    
    function claim() external {
        UserInfo storage ui = userInfo[msg.sender];
        uint lpAmount = IERC20(PAIR).balanceOf(msg.sender);
        if (lpAmount < ui.lpAmount) {
            _resetWeight(msg.sender);
            return;
        }
        
        _updateRewards(msg.sender);
        uint rewards = ui.rewards;
        ui.rewards = 0;
        ui.claimed += rewards;
        IERC20(LEG).transfer(msg.sender, rewards);
    }

    function _resetWeight(address user) private {
        UserInfo storage ui = userInfo[user];
        uint weiht = ui.weight;
        delete userInfo[msg.sender];
        totalWeight -= weiht;
    }

    function getLastTenUsers() public view returns (address[] memory) {
        return buyers;
    }

    /**哈希池 */
    function burn(uint amount) external {
        require(amount >= 1e18 && amount <= maxIn, "invalid amount");

        amount = amount / 1e18 * 1e18;
        IERC20(LEG).transferFrom(msg.sender, address(this), amount);

        totalItemNum++;
        ItemInfo memory ii;
        ii.account = msg.sender;
        ii.amount = amount;
        ii.blockNum = block.number;
        ii.time = block.timestamp;
        ii.status = 0;
        itemInfoByIndex[totalItemNum] = ii;
        indexesOf[msg.sender].push(totalItemNum);

        hashBalance += amount;

        _liquify();
	}

    function _liquify() private {
        if (liquifyBalace < minBalanceToLiquify) return;
        liquifyBalace -= minBalanceToLiquify;
        uint half = minBalanceToLiquify / 2;
        address[] memory path = new address[](2);
        path[0] = LEG;
        path[1] = WBNB;

        uint[] memory amountOuts = IRouter(ROUTER).getAmountsOut(half, path);
        uint min = amountOuts[1] * (100 - slippage) / 100;
        uint wbnbAmount = IERC20(WBNB).balanceOf(address(this));
        try IRouter(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            half,
            min,
            path,
            address(this),
            block.timestamp
        ) {} catch {}
        wbnbAmount = IERC20(WBNB).balanceOf(address(this)) - wbnbAmount;
        try IRouter(ROUTER).addLiquidity(
            LEG,
            WBNB,
            half,
            wbnbAmount,
            0,
            0,
            address(0),
            block.timestamp
        ) {} catch {}
    }

    function processLottery() public {
        bytes32 zeroHash = 0x0000000000000000000000000000000000000000000000000000000000000000;
        uint _lastProcessItemIndex = lastProcessItemIndex;
        for (uint i; i < 10; i++) {
            _lastProcessItemIndex++;
            if (_lastProcessItemIndex > totalItemNum) {
                _lastProcessItemIndex = totalItemNum;
                break;
            }
            ItemInfo storage ii = itemInfoByIndex[_lastProcessItemIndex];
            if (block.number <= ii.blockNum + 1) {
                _lastProcessItemIndex--;
                break;
            }
            bytes32 nextBlockHash = blockhash(ii.blockNum + 1);
            ii.nextBlockHash = nextBlockHash;
            if (nextBlockHash == zeroHash) {
                continue;
            }
            bytes1 lastDigit = nextBlockHash[31];
            uint8 lastDigitNum = uint8(lastDigit) & 0x0F;

            uint lastDigitOfAmount = (ii.amount / 1e18) % 2;
            
            if ((lastDigitNum % 2) == lastDigitOfAmount) {
                uint reward = ii.amount * rewardRatio / 100;
                if (hashBalance >= reward) {
                    IERC20(LEG).transfer(ii.account, reward);
                    hashBalance -= reward;
                }
                
                ii.status = 2;
            } else {
                ii.status = 1;
                uint liquifyAmount = ii.amount * 5 / 100;
                liquifyBalace += liquifyAmount;
                hashBalance -= liquifyAmount;
            }
        }
        lastProcessItemIndex = _lastProcessItemIndex;
    }

    function getItemsLenOf(address user) public view returns (uint) {
        return indexesOf[user].length;
    }

    function getUserItems(address user) public view returns (ItemInfo[] memory) {
        uint[] memory indexes = indexesOf[user];
        uint len = indexes.length;
        uint _start;
        if (len > 10) {
            _start = len - 10;
        }
        uint num = len - _start;
        ItemInfo[] memory items = new ItemInfo[](num);
        uint j = 0;
        for (uint i = _start; i < len; i++) {
            uint index = indexes[i];
            ItemInfo storage ii = itemInfoByIndex[index];
            items[j].account = ii.account;
            items[j].amount = ii.amount;
            items[j].time = ii.time;
            items[j].blockNum = ii.blockNum;
            items[j].status = ii.status;
            items[j].nextBlockHash = ii.nextBlockHash;
            j++;
        }
        return items;
    }

    function rescueERC20(address token, address to, uint amount) external onlyOwner {
        IERC20(token).transfer(to, amount);
    }

    function rescueETH(address to, uint amount) external onlyOwner {
        (bool success,) = address(to).call{value: amount}("");
        require(success);
    }
}