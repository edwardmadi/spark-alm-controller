// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { IERC20 }   from "forge-std/interfaces/IERC20.sol";
import { IERC4626 } from "forge-std/interfaces/IERC4626.sol";

import { AccessControl } from "openzeppelin-contracts/contracts/access/AccessControl.sol";

import { IALMProxy }   from "src/interfaces/IALMProxy.sol";
import { ICCTPLike }   from "src/interfaces/CCTPInterfaces.sol";
import { IRateLimits } from "src/interfaces/IRateLimits.sol";

import { RateLimitHelpers } from "src/RateLimitHelpers.sol";

interface IDaiUsdsLike {
    function dai() external view returns(address);
    function daiToUsds(address usr, uint256 wad) external;
    function usdsToDai(address usr, uint256 wad) external;
}

interface ISUSDSLike is IERC4626 {
    function usds() external view returns(address);
}

interface IVaultLike {
    function buffer() external view returns(address);
    function draw(uint256 usdsAmount) external;
    function wipe(uint256 usdsAmount) external;
}

interface IPSMLike {
    function buyGemNoFee(address usr, uint256 usdcAmount) external returns (uint256 usdsAmount);
    function fill() external returns (uint256 wad);
    function gem() external view returns(address);
    function sellGemNoFee(address usr, uint256 usdcAmount) external returns (uint256 usdsAmount);
    function to18ConversionFactor() external view returns (uint256);
}

contract MainnetController is AccessControl {

    /**********************************************************************************************/
    /*** Events                                                                                 ***/
    /**********************************************************************************************/

    // NOTE: This is used to track individual transfers for offchain processing of CCTP transactions
    event CCTPTransferInitiated(
        uint64  indexed nonce,
        uint32  indexed destinationDomain,
        bytes32 indexed mintRecipient,
        uint256 usdcAmount
    );

    event Frozen();

    event MintRecipientSet(uint32 indexed destinationDomain, bytes32 mintRecipient);

    event Reactivated();

    /**********************************************************************************************/
    /*** State variables                                                                        ***/
    /**********************************************************************************************/

    bytes32 public constant FREEZER = keccak256("FREEZER");
    bytes32 public constant RELAYER = keccak256("RELAYER");

    bytes32 public constant LIMIT_USDC_TO_CCTP   = keccak256("LIMIT_USDC_TO_CCTP");
    bytes32 public constant LIMIT_USDC_TO_DOMAIN = keccak256("LIMIT_USDC_TO_DOMAIN");
    bytes32 public constant LIMIT_USDS_MINT      = keccak256("LIMIT_USDS_MINT");
    bytes32 public constant LIMIT_USDS_TO_USDC   = keccak256("LIMIT_USDS_TO_USDC");

    address public immutable buffer;

    IALMProxy    public immutable proxy;
    IRateLimits  public immutable rateLimits;
    ICCTPLike    public immutable cctp;
    IDaiUsdsLike public immutable daiUsds;
    IPSMLike     public immutable psm;
    IVaultLike   public immutable vault;

    IERC20     public immutable dai;
    IERC20     public immutable usds;
    IERC20     public immutable usdc;
    ISUSDSLike public immutable susds;

    uint256 public immutable psmTo18ConversionFactor;

    bool public active;

    mapping(uint32 destinationDomain => bytes32 mintRecipient) public mintRecipients;

    /**********************************************************************************************/
    /*** Initialization                                                                         ***/
    /**********************************************************************************************/

    constructor(
        address admin_,
        address proxy_,
        address rateLimits_,
        address vault_,
        address psm_,
        address daiUsds_,
        address cctp_,
        address susds_
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);

        proxy      = IALMProxy(proxy_);
        rateLimits = IRateLimits(rateLimits_);
        vault      = IVaultLike(vault_);
        buffer     = IVaultLike(vault_).buffer();
        psm        = IPSMLike(psm_);
        daiUsds    = IDaiUsdsLike(daiUsds_);
        cctp       = ICCTPLike(cctp_);

        susds = ISUSDSLike(susds_ );
        dai   = IERC20(daiUsds.dai());
        usdc  = IERC20(psm.gem());
        usds  = IERC20(susds.usds());

        psmTo18ConversionFactor = psm.to18ConversionFactor();

        active = true;
    }

    /**********************************************************************************************/
    /*** Modifiers                                                                              ***/
    /**********************************************************************************************/

    modifier isActive {
        require(active, "MainnetController/not-active");
        _;
    }

    modifier rateLimited(bytes32 key, uint256 amount) {
        rateLimits.triggerRateLimitDecrease(key, amount);
        _;
    }

    modifier cancelRateLimit(bytes32 key, uint256 amount) {
        rateLimits.triggerRateLimitIncrease(key, amount);
        _;
    }

    /**********************************************************************************************/
    /*** Admin functions                                                                        ***/
    /**********************************************************************************************/

    function setMintRecipient(uint32 destinationDomain, bytes32 mintRecipient)
        external onlyRole(DEFAULT_ADMIN_ROLE)
    {
        mintRecipients[destinationDomain] = mintRecipient;
        emit MintRecipientSet(destinationDomain, mintRecipient);
    }

    /**********************************************************************************************/
    /*** Freezer functions                                                                      ***/
    /**********************************************************************************************/

    function freeze() external onlyRole(FREEZER) {
        active = false;
        emit Frozen();
    }

    function reactivate() external onlyRole(DEFAULT_ADMIN_ROLE) {
        active = true;
        emit Reactivated();
    }

    /**********************************************************************************************/
    /*** Relayer vault functions                                                                ***/
    /**********************************************************************************************/

    function mintUSDS(uint256 usdsAmount)
        external onlyRole(RELAYER) isActive rateLimited(LIMIT_USDS_MINT, usdsAmount)
    {
        // Mint USDS into the buffer
        proxy.doCall(
            address(vault),
            abi.encodeCall(vault.draw, (usdsAmount))
        );

        // Transfer USDS from the buffer to the proxy
        proxy.doCall(
            address(usds),
            abi.encodeCall(usds.transferFrom, (buffer, address(proxy), usdsAmount))
        );
    }

    function burnUSDS(uint256 usdsAmount)
        external onlyRole(RELAYER) isActive cancelRateLimit(LIMIT_USDS_MINT, usdsAmount)
    {
        // Transfer USDS from the proxy to the buffer
        proxy.doCall(
            address(usds),
            abi.encodeCall(usds.transfer, (buffer, usdsAmount))
        );

        // Burn USDS from the buffer
        proxy.doCall(
            address(vault),
            abi.encodeCall(vault.wipe, (usdsAmount))
        );
    }

    /**********************************************************************************************/
    /*** Relayer sUSDS functions                                                                 ***/
    /**********************************************************************************************/

    function depositToSUSDS(uint256 usdsAmount)
        external onlyRole(RELAYER) isActive returns (uint256 shares)
    {
        // Approve USDS to sUSDS from the proxy (assumes the proxy has enough USDS).
        proxy.doCall(
            address(usds),
            abi.encodeCall(usds.approve, (address(susds), usdsAmount))
        );

        // Deposit USDS into sUSDS, proxy receives sUSDS shares, decode the resulting shares
        shares = abi.decode(
            proxy.doCall(
                address(susds),
                abi.encodeCall(susds.deposit, (usdsAmount, address(proxy)))
            ),
            (uint256)
        );
    }

    function withdrawFromSUSDS(uint256 usdsAmount)
        external onlyRole(RELAYER) isActive returns (uint256 shares)
    {
        // Withdraw USDS from sUSDS, decode resulting shares.
        // Assumes proxy has adequate sUSDS shares.
        shares = abi.decode(
            proxy.doCall(
                address(susds),
                abi.encodeCall(susds.withdraw, (usdsAmount, address(proxy), address(proxy)))
            ),
            (uint256)
        );
    }

    function redeemFromSUSDS(uint256 susdsSharesAmount)
        external onlyRole(RELAYER) isActive returns (uint256 assets)
    {
        // Redeem shares for USDS from sUSDS, decode the resulting assets.
        // Assumes proxy has adequate sUSDS shares.
        assets = abi.decode(
            proxy.doCall(
                address(susds),
                abi.encodeCall(susds.redeem, (susdsSharesAmount, address(proxy), address(proxy)))
            ),
            (uint256)
        );
    }

    /**********************************************************************************************/
    /*** Relayer PSM functions                                                                  ***/
    /**********************************************************************************************/

    // NOTE: The param `usdcAmount` is denominated in 1e6 precision to match how PSM uses
    //       USDC precision for both `buyGemNoFee` and `sellGemNoFee`
    function swapUSDSToUSDC(uint256 usdcAmount)
        external onlyRole(RELAYER) isActive rateLimited(LIMIT_USDS_TO_USDC, usdcAmount)
    {
        uint256 usdsAmount = usdcAmount * psmTo18ConversionFactor;

        // Approve USDS to DaiUsds migrator from the proxy (assumes the proxy has enough USDS)
        proxy.doCall(
            address(usds),
            abi.encodeCall(usds.approve, (address(daiUsds), usdsAmount))
        );

        // Swap USDS to DAI 1:1
        proxy.doCall(
            address(daiUsds),
            abi.encodeCall(daiUsds.usdsToDai, (address(proxy), usdsAmount))
        );

        // Approve DAI to PSM from the proxy because conversion from USDS to DAI was 1:1
        proxy.doCall(
            address(dai),
            abi.encodeCall(dai.approve, (address(psm), usdsAmount))
        );

        // Swap DAI to USDC through the PSM
        proxy.doCall(
            address(psm),
            abi.encodeCall(psm.buyGemNoFee, (address(proxy), usdcAmount))
        );
    }

    function swapUSDCToUSDS(uint256 usdcAmount)
        external onlyRole(RELAYER) isActive cancelRateLimit(LIMIT_USDS_TO_USDC, usdcAmount)
    {
        // Approve USDC to PSM from the proxy (assumes the proxy has enough USDC)
        proxy.doCall(
            address(usdc),
            abi.encodeCall(usdc.approve, (address(psm), usdcAmount))
        );

        // Max USDC that can be swapped to DAI in one call
        uint256 limit = dai.balanceOf(address(psm)) / psmTo18ConversionFactor;

        if (usdcAmount <= limit) {
            _swapUSDCToDAI(usdcAmount);
        } else {
            uint256 remainingUsdcToSwap = usdcAmount;

            // Refill the PSM with DAI as many times as needed to get to the full `usdcAmount`.
            // If the PSM cannot be filled with the full amount, psm.fill() will revert
            // with `DssLitePsm/nothing-to-fill` since rush() will return 0.
            // This is desired behavior because this function should only succeed if the full
            // `usdcAmount` can be swapped.
            while (remainingUsdcToSwap > 0) {
                psm.fill();

                limit = dai.balanceOf(address(psm)) / psmTo18ConversionFactor;

                uint256 swapAmount = remainingUsdcToSwap < limit ? remainingUsdcToSwap : limit;

                _swapUSDCToDAI(swapAmount);

                remainingUsdcToSwap -= swapAmount;
            }
        }

        uint256 daiAmount = usdcAmount * psmTo18ConversionFactor;

        // Approve DAI to DaiUsds migrator from the proxy (assumes the proxy has enough DAI)
        proxy.doCall(
            address(dai),
            abi.encodeCall(dai.approve, (address(daiUsds), daiAmount))
        );

        // Swap DAI to USDS 1:1
        proxy.doCall(
            address(daiUsds),
            abi.encodeCall(daiUsds.daiToUsds, (address(proxy), daiAmount))
        );
    }

    /**********************************************************************************************/
    /*** Relayer bridging functions                                                             ***/
    /**********************************************************************************************/

    function transferUSDCToCCTP(uint256 usdcAmount, uint32 destinationDomain)
        external
        onlyRole(RELAYER)
        isActive
        rateLimited(LIMIT_USDC_TO_CCTP, usdcAmount)
        rateLimited(
            RateLimitHelpers.makeDomainKey(LIMIT_USDC_TO_DOMAIN, destinationDomain),
            usdcAmount
        )
    {
        bytes32 mintRecipient = mintRecipients[destinationDomain];

        require(mintRecipient != 0, "MainnetController/domain-not-configured");

        // Approve USDC to CCTP from the proxy (assumes the proxy has enough USDC)
        proxy.doCall(
            address(usdc),
            abi.encodeCall(usdc.approve, (address(cctp), usdcAmount))
        );

        // If amount is larger than limit it must be split into multiple calls
        uint256 burnLimit = cctp.localMinter().burnLimitsPerMessage(address(usdc));

        while (usdcAmount > burnLimit) {
            _initiateCCTPTransfer(burnLimit, destinationDomain, mintRecipient);
            usdcAmount -= burnLimit;
        }

        // Send remaining amount (if any)
        if (usdcAmount > 0) {
            _initiateCCTPTransfer(usdcAmount, destinationDomain, mintRecipient);
        }
    }

    /**********************************************************************************************/
    /*** Internal helper functions                                                              ***/
    /**********************************************************************************************/

    function _initiateCCTPTransfer(
        uint256 usdcAmount,
        uint32  destinationDomain,
        bytes32 mintRecipient
    )
        internal
    {
        uint64 nonce = abi.decode(
            proxy.doCall(
                address(cctp),
                abi.encodeCall(
                    cctp.depositForBurn,
                    (
                        usdcAmount,
                        destinationDomain,
                        mintRecipient,
                        address(usdc)
                    )
                )
            ),
            (uint64)
        );

        emit CCTPTransferInitiated(nonce, destinationDomain, mintRecipient, usdcAmount);
    }

    function _swapUSDCToDAI(uint256 usdcAmount) internal {
        // Swap USDC to DAI through the PSM (1:1 since sellGemNoFee is used)
        proxy.doCall(
            address(psm),
            abi.encodeCall(psm.sellGemNoFee, (address(proxy), usdcAmount))
        );
    }

}

