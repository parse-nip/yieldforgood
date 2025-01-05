// SPDX-License-Identifier: MIT
pragma solidity ^0.8.5;

interface IBlast {
    function configureAutomaticYield() external;
}

interface IBlastPoints {
    function configurePointsOperator(address operator) external;
    function configurePointsOperatorOnBehalf(address contractAddress, address operator) external;
}

// Interface for sending WETH to Ethereum mainnet as ETH via across.to
interface V3SpokePoolInterface {
    function depositV3(
        address depositor,
        address recipient,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes calldata message
    ) external payable;
}

interface IWETH {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

interface IERC20 {
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}


contract Charity {
    uint256 public totalAmountETH; // Total amount stored in contract
    uint256 public totalAmountUSDB; // Total amount stored in contract

    mapping(address => uint256) public depositedAmount; // Individual deposits
    mapping(address => uint256) public depositedAmountUSDB; // Individual deposits
    mapping(address => uint256) public userLockTime; // Lock time per user
    address public OWNER; // Deployer of contract
    address public SPOKE_POOL = 0x2D509190Ed0172ba588407D4c2df918F955Cc6E1; // Blast Spoke Pool address
    address public CHARITY_ADDRESS; // Address of the charity
    IWETH public weth; // WETH interface
    IERC20 public usdb;
    mapping(address => bool) public isWhitelisted;
    address public wethAddress;
    mapping(address => bool) locked;
    // Events
    event Deposited(address indexed depositor, uint256 amountDeposited, uint256 lockTime);
    event Withdrawn(address indexed withdrawer, uint256 amountWithdrawn);
    event YieldSent(address indexed charity, uint256 yieldAmount, uint256 fee);
    event Error(string reason);

    // Modifiers
    modifier onlyWhitelisted {
        require(isWhitelisted[msg.sender], "Caller not whitelisted");
        _;
    }

    modifier onlyOwner {
        require(msg.sender == OWNER, "Only the owner can perform this action");
        _;
    }

    modifier nonReentrant {
        require(!locked[msg.sender], "Non reetrant.");
        locked[msg.sender] = true;
        _;
        locked[msg.sender] = false;
    }


    //NOTE: Is possible to hardcode these values for WETH and USDB - but would require further adaptation for other chains...

    constructor(address _pointsOperator, address _charityAddress, address _wethAddress, address _usdbAddress) {
        OWNER = msg.sender;
        IBlastPoints(0x2536FE9ab3F511540F2f9e2eC2A805005C3Dd800).configurePointsOperator(_pointsOperator);
        CHARITY_ADDRESS = _charityAddress;
        weth = IWETH(_wethAddress);
        wethAddress = _wethAddress;
        usdb = IERC20(_usdbAddress);
    }

    // Add a new whitelisted address
    function addWhitelistedAddress(address newAddress) external onlyOwner {
        isWhitelisted[newAddress] = true;
    }

    // Remove an address from the whitelist
    function removeWhitelistedAddress(address oldAddress) external onlyOwner {
        isWhitelisted[oldAddress] = false;
    }

    // Change ownership of the contract
    function switchOwner(address newOwner) external onlyOwner {
        OWNER = newOwner;
    }

    // Deposit ETH, convert to WETH, and lock for a specified time
    // TO-DO: Find a better method of determining currency. Bool won't work as we support more.
    function deposit(uint256 lockTime, bool isUSDB, uint256 amount) payable external nonReentrant{
        require(lockTime >= 1 weeks, "Lock time must be at least 1 week");

        if(isUSDB){
            require(amount > 0, "Must send USDB or ETH to make a deposit");
            require(usdb.allowance(msg.sender, address(this)) > amount,"Must approve USDB spending."); //Ensure approvals for token transfer

            usdb.transferFrom(msg.sender, address(this), amount); 

            depositedAmountUSDB[msg.sender] += amount;
            userLockTime[msg.sender] = block.timestamp + lockTime;
            totalAmountUSDB += amount; //How to calculate totalAmountETH for USDB (it's in different units obv... to ETH)
        }
        else {
        require(msg.value > 0, "Must send USDB or ETH to make a deposit");
        weth.deposit{value: msg.value}();

        depositedAmount[msg.sender] += msg.value;
        userLockTime[msg.sender] = block.timestamp + lockTime;
        totalAmountETH += msg.value;

        // Convert ETH to WETH

        emit Deposited(msg.sender, msg.value, lockTime);
        }

    }

    // Withdraw deposited ETH after lock time
    function withdraw(bool isUSDB) external nonReentrant{
        require(block.timestamp >= userLockTime[msg.sender], "Funds are still locked");
        uint256 amountToWithdraw = 0;
        if (isUSDB){
            amountToWithdraw = depositedAmountUSDB[msg.sender];
            require(amountToWithdraw > 0, "No funds to withdraw");
            usdb.transfer(msg.sender, amountToWithdraw);
            depositedAmountUSDB[msg.sender] = 0;
            totalAmountUSDB -= amountToWithdraw;
            emit Withdrawn(msg.sender, amountToWithdraw);

        }
        else{
            amountToWithdraw = depositedAmount[msg.sender];
            require(amountToWithdraw > 0, "No funds to withdraw");

                // Convert WETH back to ETH and transfer to user
                try weth.withdraw(amountToWithdraw){
                    payable(msg.sender).transfer(amountToWithdraw);

                    depositedAmount[msg.sender] = 0;
                    totalAmountETH -= amountToWithdraw;

                    emit Withdrawn(msg.sender, amountToWithdraw);
                }
                catch{
                    emit Error("Withdrawl of ETH failed.");
                }

        }




    }

    // Update charity address - consider deleting as it adds a risk
    function updateCharity(address newCharityAddress) public onlyOwner {
        CHARITY_ADDRESS = newCharityAddress;
    }

    // Fetch current yield amount
    function fetchYieldAmountETH() external view returns (uint256) {
        return weth.balanceOf(address(this)) - totalAmountETH;
    }

    function fetchYieldAmountUSDB() external view returns (uint256) {
        return usdb.balanceOf(address(this)) - totalAmountUSDB;
    }


    // Approve WETH spending
    // TO-DO: Prevent rug pulls by adding a modifier to this, preventing the owner from taking funds
    // Make it internal and call it when Across needs it.

    function approveWETHSpender(address spender, uint256 amount) external onlyOwner {
        require(weth.approve(spender, amount), "WETH approval failed");
    }

    function approveUSDBSpender(address spender, uint256 amount) external onlyOwner {
        require(usdb.approve(spender, amount), "USDB approval failed");
    }
    // Automatically convert incoming ETH to WETH
    receive() external payable {
        if (msg.sender != wethAddress){
        weth.deposit{value: msg.value}(); //Prevents re depositing withdrawals
        }
    }

    // Send yield to charity with a specified bridge fee
    function sendYieldToCharityETH(uint256 bridgeFee) external onlyWhitelisted {
        uint256 currentBalance = weth.balanceOf(address(this));
        uint256 yieldAmount = currentBalance > totalAmountETH ? currentBalance - totalAmountETH : 0;

        require(yieldAmount > 0, "No yield available");
        require(yieldAmount >= bridgeFee, "Insufficient yield to cover the relay fee");

        // Approve WETH for the Spoke Pool
        bool approvalSuccess = weth.approve(SPOKE_POOL, yieldAmount);
        require(approvalSuccess, "Approval for Spoke Pool failed");

        try V3SpokePoolInterface(SPOKE_POOL).depositV3(
            address(this),
            CHARITY_ADDRESS,
            address(weth),
            address(0),
            yieldAmount,
            yieldAmount - bridgeFee,
            42161, // Ethereum chain ID
            address(0),
            uint32(block.timestamp - 36),
            uint32(block.timestamp + 18000),
            uint32(0),
            bytes("")
        ) {
            emit YieldSent(CHARITY_ADDRESS, yieldAmount, bridgeFee);
        } catch {
            emit Error("Yield transfer to charity failed");
            revert("Failed to send yield to charity");
        }
    }

        function sendYieldToCharityUSDB(uint256 bridgeFee) external onlyWhitelisted {
        uint256 currentBalance = usdb.balanceOf(address(this));
        uint256 yieldAmount = currentBalance > totalAmountUSDB ? currentBalance - totalAmountUSDB : 0;

        require(yieldAmount > 0, "No yield available");
        require(yieldAmount >= bridgeFee, "Insufficient yield to cover the relay fee");

        // Approve WETH for the Spoke Pool
        bool approvalSuccess = usdb.approve(SPOKE_POOL, yieldAmount);
        require(approvalSuccess, "Approval for Spoke Pool failed");

        try V3SpokePoolInterface(SPOKE_POOL).depositV3(
            address(this),
            CHARITY_ADDRESS,
            address(usdb),
            address(0),
            yieldAmount,
            yieldAmount - bridgeFee,
            42161, // Ethereum chain ID
            address(0),
            uint32(block.timestamp - 36),
            uint32(block.timestamp + 18000),
            uint32(0),
            bytes("")
        ) {
            emit YieldSent(CHARITY_ADDRESS, yieldAmount, bridgeFee);
        } catch {
            emit Error("Yield transfer to charity failed");
            revert("Failed to send yield to charity");
        }
    }

}
