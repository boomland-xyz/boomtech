// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";

interface IBlast {
    function configureAutomaticYield() external;
}

contract BoomTech is OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using AddressUpgradeable for address payable;

    uint256 private constant BASE_DIVIDER = 16000;
    uint256 private constant ACC_YIELD_PRECISION = 1e12;

    address payable public protocolFeeDestination;
    uint256 public protocolFeePercent;
    uint256 public subjectFeePercent;

    uint256 public totalKeysSupply;
    mapping(address => uint256) public keysSupply;
    mapping(address => mapping(address => uint256)) public keysBalance;

    uint256 public lastYieldEth;
    mapping(address => uint256) public accYieldPerUnit;
    mapping(address => mapping(address => int256)) public yieldDebt;

    event SetProtocolFeeDestination(address indexed destination);
    event SetProtocolFeePercent(uint256 percent);
    event SetSubjectFeePercent(uint256 percent);

    event LogUpdateYield(address indexed subject, uint256 lastYieldEth, uint256 accYieldPerUnit);
    event ClaimYield(address indexed subject, address indexed holder, uint256 amount);

    event Trade(
        address indexed trader,
        address indexed subject,
        bool indexed isBuy,
        uint256 amount,
        uint256 price,
        uint256 protocolFee,
        uint256 subjectFee,
        uint256 supply
    );

    function initialize(
        address payable _protocolFeeDestination,
        uint256 _protocolFeePercent,
        uint256 _subjectFeePercent
    ) public initializer {
        __Ownable_init();
        __ReentrancyGuard_init();

        IBlast(0x4300000000000000000000000000000000000002).configureAutomaticYield();

        protocolFeeDestination = _protocolFeeDestination;
        protocolFeePercent = _protocolFeePercent;
        subjectFeePercent = _subjectFeePercent;

        emit SetProtocolFeeDestination(_protocolFeeDestination);
        emit SetProtocolFeePercent(_protocolFeePercent);
        emit SetSubjectFeePercent(_subjectFeePercent);
    }

    function setProtocolFeeDestination(address payable _feeDestination) public onlyOwner {
        protocolFeeDestination = _feeDestination;
        emit SetProtocolFeeDestination(_feeDestination);
    }

    function setProtocolFeePercent(uint256 _feePercent) public onlyOwner {
        protocolFeePercent = _feePercent;
        emit SetProtocolFeePercent(_feePercent);
    }

    function setSubjectFeePercent(uint256 _feePercent) public onlyOwner {
        subjectFeePercent = _feePercent;
        emit SetSubjectFeePercent(_feePercent);
    }

    function getPrice(uint256 supply, uint256 amount) public pure returns (uint256) {
        uint256 sum1 = ((supply * (supply + 1)) * (2 * supply + 1)) / 6;
        uint256 sum2 = (((supply + amount) * (supply + 1 + amount)) * (2 * (supply + amount) + 1)) / 6;
        uint256 summation = sum2 - sum1;
        return (summation * 1 ether) / BASE_DIVIDER;
    }

    function getBuyPrice(address subject, uint256 amount) public view returns (uint256) {
        return getPrice(keysSupply[subject], amount);
    }

    function getSellPrice(address subject, uint256 amount) public view returns (uint256) {
        return getPrice(keysSupply[subject] - amount, amount);
    }

    function getBuyPriceAfterFee(address subject, uint256 amount) public view returns (uint256) {
        uint256 price = getBuyPrice(subject, amount);
        uint256 protocolFee = (price * protocolFeePercent) / 1 ether;
        uint256 subjectFee = (price * subjectFeePercent) / 1 ether;
        return price + protocolFee + subjectFee;
    }

    function getSellPriceAfterFee(address subject, uint256 amount) public view returns (uint256) {
        uint256 price = getSellPrice(subject, amount);
        uint256 protocolFee = (price * protocolFeePercent) / 1 ether;
        uint256 subjectFee = (price * subjectFeePercent) / 1 ether;
        return price - protocolFee - subjectFee;
    }

    function updateYield(address subject) private {
        uint256 eth = address(this).balance;
        if (eth > lastYieldEth) {
            uint256 supply = keysSupply[subject];
            if (supply > 0) {
                accYieldPerUnit[subject] += ((eth - lastYieldEth) * supply) / totalKeysSupply;
            }
            lastYieldEth = eth;
            emit LogUpdateYield(subject, lastYieldEth, accYieldPerUnit[subject]);
        }
    }

    function buyKeys(address subject, uint256 amount) external payable nonReentrant {
        uint256 price = getBuyPrice(subject, amount);
        uint256 subjectFee = (price * subjectFeePercent) / 1 ether;
        uint256 protocolFee = (price * protocolFeePercent) / 1 ether;

        require(msg.value >= price + protocolFee + subjectFee, "Insufficient payment");

        uint256 supply = keysSupply[subject];

        keysBalance[subject][msg.sender] += amount;
        supply += amount;
        totalKeysSupply += amount;
        keysSupply[subject] = supply;

        updateYield(subject);
        yieldDebt[subject][msg.sender] += int256((amount * accYieldPerUnit[subject]) / ACC_YIELD_PRECISION);

        protocolFeeDestination.sendValue(protocolFee);
        payable(subject).sendValue(subjectFee);
        if (msg.value > price + protocolFee + subjectFee) {
            uint256 refund = msg.value - price - protocolFee - subjectFee;
            payable(msg.sender).sendValue(refund);
        }

        emit Trade(msg.sender, subject, true, amount, price, protocolFee, subjectFee, supply);
    }

    function sellKeys(address subject, uint256 amount) external nonReentrant {
        require(keysBalance[subject][msg.sender] >= amount, "Insufficient keys");

        uint256 price = getSellPrice(subject, amount);
        uint256 subjectFee = (price * subjectFeePercent) / 1 ether;
        uint256 protocolFee = (price * protocolFeePercent) / 1 ether;
        uint256 supply = keysSupply[subject];

        keysBalance[subject][msg.sender] -= amount;
        supply -= amount;
        totalKeysSupply -= amount;
        keysSupply[subject] = supply;

        updateYield(subject);
        yieldDebt[subject][msg.sender] -= int256((amount * accYieldPerUnit[subject]) / ACC_YIELD_PRECISION);

        uint256 netAmount = price - protocolFee - subjectFee;
        payable(msg.sender).sendValue(netAmount);
        protocolFeeDestination.sendValue(protocolFee);
        payable(subject).sendValue(subjectFee);

        emit Trade(msg.sender, subject, false, amount, price, protocolFee, subjectFee, supply);
    }

    function claimableYield(address subject, address holder) external view returns (uint256 claimable) {
        uint256 acc = accYieldPerUnit[subject];
        uint256 eth = address(this).balance;
        if (eth > lastYieldEth) {
            acc += ((eth - lastYieldEth) * keysSupply[subject]) / totalKeysSupply;
        }
        claimable = uint256(
            int256((keysBalance[subject][holder] * acc) / ACC_YIELD_PRECISION) - yieldDebt[subject][holder]
        );
    }

    function claimYield(address subject) external nonReentrant {
        updateYield(subject);

        int256 acc = int256((keysBalance[subject][msg.sender] * accYieldPerUnit[subject]) / ACC_YIELD_PRECISION);
        uint256 claimable = uint256(acc - yieldDebt[subject][msg.sender]);

        yieldDebt[subject][msg.sender] = acc;

        if (claimable > 0) {
            payable(msg.sender).sendValue(claimable);
        }

        emit ClaimYield(subject, msg.sender, claimable);
    }

    function sellKeysAndClaimYield(address subject, uint256 amount) external nonReentrant {
        require(keysBalance[subject][msg.sender] >= amount, "Insufficient keys");

        uint256 price = getSellPrice(subject, amount);
        uint256 subjectFee = (price * subjectFeePercent) / 1 ether;
        uint256 protocolFee = (price * protocolFeePercent) / 1 ether;
        uint256 supply = keysSupply[subject];

        keysBalance[subject][msg.sender] -= amount;
        supply -= amount;
        totalKeysSupply -= amount;
        keysSupply[subject] = supply;

        updateYield(subject);
        int256 acc = int256((amount * accYieldPerUnit[subject]) / ACC_YIELD_PRECISION);
        uint256 claimable = uint256(acc - yieldDebt[subject][msg.sender]);
        yieldDebt[subject][msg.sender] = acc;

        uint256 netAmount = price - protocolFee - subjectFee;
        payable(msg.sender).sendValue(netAmount + claimable);
        protocolFeeDestination.sendValue(protocolFee);
        payable(subject).sendValue(subjectFee);

        emit Trade(msg.sender, subject, false, amount, price, protocolFee, subjectFee, supply);
        emit ClaimYield(subject, msg.sender, claimable);
    }
}
