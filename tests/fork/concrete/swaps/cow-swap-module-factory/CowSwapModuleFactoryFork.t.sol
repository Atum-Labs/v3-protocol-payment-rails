// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { Vm } from "forge-std/src/Vm.sol";
import { CowSwapModule } from "../../../../../src/modules/swaps/CowSwapModule.sol";
import { CowSwapModuleFactory } from "../../../../../src/modules/swaps/CowSwapModuleFactory.sol";
import { IGPv2Settlement } from "../../../../../src/interfaces/IGPv2Settlement.sol";
import { PaymentRails } from "../../../../../src/core/PaymentRails.sol";
import { DataTypes } from "../../../../../src/types/DataTypes.sol";
import { Errors } from "../../../../../src/libraries/Errors.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title CowSwapModuleFactoryFork_Test
/// @notice Fork tests proving the factory deploys working CowSwapModules against the real
/// GPv2Settlement on Ethereum mainnet — constructor wiring, CREATE2 prediction, and a real
/// order executed end-to-end through PaymentRails via a factory-deployed module.
contract CowSwapModuleFactoryFork_Test is Test {
    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    event OrderCreated(
        bytes32 indexed orderId,
        address indexed paymentRails,
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        uint256 buyAmount,
        uint32 validTo,
        bytes32 appData
    );

    /*//////////////////////////////////////////////////////////////////////////
                                MAINNET CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    address internal constant GPV2_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    address internal constant GPV2_VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address internal constant ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal constant USDC_USD_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    bytes4 internal constant EIP1271_MAGIC = 0x1626ba7e;

    uint256 internal constant USDC_SELL_AMOUNT = 10_000e6; // 10,000 USDC
    uint16 internal constant SLIPPAGE_BPS = 500; // 5%
    uint256 internal constant MAX_STALENESS = 86_400; // 1 day — generous for fork testing
    uint32 internal constant DEFAULT_VALIDITY = 3600; // 1 hour
    bytes32 internal constant DEFAULT_APP_DATA = keccak256("receivables-paymentRails-v1");
    bytes32 internal constant DEFAULT_SALT = bytes32(uint256(1));

    /*//////////////////////////////////////////////////////////////////////////
                                TEST CONTRACTS
    //////////////////////////////////////////////////////////////////////////*/

    CowSwapModuleFactory internal factory;
    PaymentRails internal paymentRails;
    address internal owner;

    bytes32 internal realDomainSeparator;

    /*//////////////////////////////////////////////////////////////////////////
                                    SETUP
    //////////////////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        string memory rpcUrl = vm.envOr("ETHEREUM_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
        }

        vm.createSelectFork("ethereum", 21_900_000);

        owner = makeAddr("owner");

        realDomainSeparator = IGPv2Settlement(GPV2_SETTLEMENT).domainSeparator();

        vm.startPrank(owner);
        paymentRails = new PaymentRails(owner);
        factory = new CowSwapModuleFactory(owner, GPV2_SETTLEMENT, address(0), 0);
        vm.stopPrank();

        deal(USDC, address(paymentRails), USDC_SELL_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            CONSTRUCTOR AGAINST REAL SETTLEMENT
    //////////////////////////////////////////////////////////////////////////*/

    function test_Fork_FactoryDeploysAgainstRealSettlement() external view {
        assertEq(factory.cowSettlement(), GPV2_SETTLEMENT);
        assertTrue(address(factory).code.length > 0);
    }

    function test_Fork_RevertWhen_SettlementIsEOA() external {
        address eoa = makeAddr("realChainEoa");
        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModuleFactory_SettlementNotContract.selector, eoa));
        new CowSwapModuleFactory(owner, eoa, address(0), 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            CREATE AGAINST REAL SETTLEMENT
    //////////////////////////////////////////////////////////////////////////*/

    function test_Fork_Create_WiresRealDomainSeparator() external {
        vm.prank(owner);
        address module = factory.create(owner, address(paymentRails));
        assertEq(CowSwapModule(module).cowDomainSeparator(), realDomainSeparator);
    }

    function test_Fork_Create_WiresRealVaultRelayer() external {
        vm.prank(owner);
        address module = factory.create(owner, address(paymentRails));
        assertEq(CowSwapModule(module).vaultRelayer(), GPV2_VAULT_RELAYER);
    }

    function test_Fork_Create_RegistersModule() external {
        vm.prank(owner);
        address module = factory.create(owner, address(paymentRails));
        assertTrue(factory.isDeployedModule(module));

        address[] memory modules = factory.getModulesForPaymentRails(address(paymentRails));
        assertEq(modules.length, 1);
        assertEq(modules[0], module);
    }

    function test_Fork_CreateDeterministic_MatchesPrediction() external {
        address predicted = factory.predictDeterministicAddress(owner, address(paymentRails), DEFAULT_SALT);

        vm.prank(owner);
        address module = factory.createDeterministic(owner, address(paymentRails), DEFAULT_SALT);

        assertEq(module, predicted);
        assertEq(CowSwapModule(module).cowDomainSeparator(), realDomainSeparator);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    AUTHORIZATION AGAINST A REAL PAYMENT RAILS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev A non-owner cannot register anything; the live PaymentRails' registry entry stays empty.
    function test_Fork_RevertWhen_NonOwnerCreatesAgainstRealRails() external {
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        factory.create(attacker, address(paymentRails));

        assertEq(factory.getModulesForPaymentRails(address(paymentRails)).length, 0);
    }

    /// @dev Production flow: mint a module for a PaymentRails the factory owner does not own.
    function test_Fork_FactoryOwner_CreatesModuleForCustomerOwnedRails() external {
        address customer = makeAddr("customer");
        PaymentRails customerRails = new PaymentRails(customer);
        assertTrue(customerRails.owner() != owner);

        vm.prank(owner);
        address module = factory.create(customer, address(customerRails));

        assertEq(CowSwapModule(module).owner(), customer);
        assertEq(CowSwapModule(module).paymentRails(), address(customerRails));
        assertEq(CowSwapModule(module).cowDomainSeparator(), realDomainSeparator);
        assertEq(factory.getModulesForPaymentRails(address(customerRails))[0], module);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        END-TO-END: REAL ORDER VIA FACTORY MODULE
    //////////////////////////////////////////////////////////////////////////*/

    function test_Fork_FactoryModule_ExecutesRealUsdcOrderViaPaymentRails() external {
        // Deploy the module through the factory — the exact flow production will use, called by the
        // factory owner as the factory now requires.
        vm.prank(owner);
        address module = factory.create(owner, address(paymentRails));

        bytes memory params = CowSwapModule(module)
            .encodeParams(
                DataTypes.CowSwapParams({
                    targetToken: WETH,
                    maxSlippageBps: SLIPPAGE_BPS,
                    sellTokenPriceFeed: USDC_USD_FEED,
                    buyTokenPriceFeed: ETH_USD_FEED,
                    maxStaleness: MAX_STALENESS,
                    validityDuration: DEFAULT_VALIDITY,
                    appData: DEFAULT_APP_DATA
                })
            );

        vm.prank(owner);
        paymentRails.configureToken(USDC, "COWSWAP", module, USDC_SELL_AMOUNT, params, true);

        vm.recordLogs();
        bool success = paymentRails.executeAction(USDC, USDC_SELL_AMOUNT);
        assertTrue(success, "executeAction should succeed via factory-deployed module");

        // Extract the orderId from the OrderCreated event emitted by the module.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 orderId;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == OrderCreated.selector && logs[i].emitter == module) {
                orderId = logs[i].topics[1];
                break;
            }
        }
        assertTrue(orderId != bytes32(0), "OrderCreated event should be emitted");

        // The module holds the sell tokens, approved to the real vault relayer, and the
        // order validates via EIP-1271 exactly as a real CowSwap solver would check it.
        assertEq(IERC20(USDC).balanceOf(module), USDC_SELL_AMOUNT);
        assertEq(IERC20(USDC).allowance(module, GPV2_VAULT_RELAYER), type(uint256).max);
        assertEq(CowSwapModule(module).isValidSignature(orderId, abi.encode(orderId)), EIP1271_MAGIC);
    }
}
