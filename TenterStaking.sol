// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract TenterStaking is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant REWARD_MANAGER_ROLE = keccak256("REWARD_MANAGER_ROLE");
    uint256 private constant PRECISION = 1e24;
    uint256 public constant MIN_LOCK_DURATION = 7 days;

    IERC20 public immutable tnusd;

    uint256 public rewardRate;
    uint256 public periodFinish;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public rewardReserve;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    mapping(address => uint256) public lastStakeTime;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    event Staked(address indexed user, uint256 amount, uint256 unlockTime);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(uint256 reward, uint256 duration, uint256 periodFinish);
    event ERC20Recovered(address indexed token, address indexed to, uint256 amount);
    event UnallocatedTnusdRecovered(address indexed to, uint256 amount);

    constructor(address _tnusd, address admin) {
        require(_tnusd != address(0) && admin != address(0), "Direccion invalida");
        tnusd = IERC20(_tnusd);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REWARD_MANAGER_ROLE, admin);
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored +
            (((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * PRECISION) / _totalSupply);
    }

    function earned(address account) public view returns (uint256) {
        return
            ((_balances[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / PRECISION) +
            rewards[account];
    }

    function unlockTimeOf(address account) external view returns (uint256) {
        if (_balances[account] == 0) return 0;
        return lastStakeTime[account] + MIN_LOCK_DURATION;
    }

    function stake(uint256 amount) external nonReentrant whenNotPaused updateReward(msg.sender) {
        require(amount > 0, "Monto debe ser mayor a 0");
        _totalSupply += amount;
        _balances[msg.sender] += amount;
        lastStakeTime[msg.sender] = block.timestamp;

        tnusd.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount, block.timestamp + MIN_LOCK_DURATION);
    }

    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Monto debe ser mayor a 0");
        require(_balances[msg.sender] >= amount, "Saldo insuficiente");
        require(
            block.timestamp >= lastStakeTime[msg.sender] + MIN_LOCK_DURATION,
            "Capital bloqueado por 7 dias desde el ultimo deposito"
        );

        _totalSupply -= amount;
        _balances[msg.sender] -= amount;
        tnusd.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            require(rewardReserve >= reward, "Reserva de recompensas insuficiente");
            rewards[msg.sender] = 0;
            rewardReserve -= reward;
            tnusd.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function exit() external {
        withdraw(_balances[msg.sender]);
        getReward();
    }

    function notifyRewardAmount(uint256 reward, uint256 duration)
        external
        onlyRole(REWARD_MANAGER_ROLE)
        whenNotPaused
        updateReward(address(0))
    {
        require(duration > 0, "Duracion invalida");
        require(reward > 0, "Recompensa debe ser mayor a 0");

        uint256 leftover = 0;
        if (block.timestamp < periodFinish) {
            uint256 remaining = periodFinish - block.timestamp;
            leftover = remaining * rewardRate;
        }

        uint256 newRewardRate = (reward + leftover) / duration;
        require(newRewardRate > 0, "Recompensa muy baja para esa duracion");

        uint256 actualRewardToEmit = (newRewardRate * duration) - leftover;

        tnusd.safeTransferFrom(msg.sender, address(this), actualRewardToEmit);
        rewardReserve += actualRewardToEmit;

        rewardRate = newRewardRate;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + duration;

        emit RewardAdded(actualRewardToEmit, duration, periodFinish);
    }

    function recoverERC20(address token, address to, uint256 amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        require(token != address(tnusd), "Usar recoverUnallocatedTnusd para TNUSD");
        require(to != address(0), "Direccion destino invalida");
        require(amount > 0, "Monto debe ser mayor a 0");

        IERC20(token).safeTransfer(to, amount);
        emit ERC20Recovered(token, to, amount);
    }

    function recoverUnallocatedTnusd(address to, uint256 amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        require(to != address(0), "Direccion destino invalida");
        require(amount > 0, "Monto debe ser mayor a 0");

        uint256 committedBalance = _totalSupply + rewardReserve;
        uint256 contractBalance = tnusd.balanceOf(address(this));
        require(contractBalance > committedBalance, "No hay TNUSD excedente");

        uint256 excessAvailable = contractBalance - committedBalance;
        require(amount <= excessAvailable, "Excede el TNUSD no asignado");

        tnusd.safeTransfer(to, amount);
        emit UnallocatedTnusdRecovered(to, amount);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }
}