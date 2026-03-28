// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import {BaseDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";
import {AaveV3DecoderAndSanitizer} from "src/base/DecodersAndSanitizers/Protocols/AaveV3DecoderAndSanitizer.sol";

/// @title ClawTogetherDecoderAndSanitizer
/// @notice Decoder and sanitizer for ClawTogether vault operations.
///         Supports Aave V3 supply/withdraw and ERC20 approve/transfer
///         (inherited from BaseDecoderAndSanitizer).
contract ClawTogetherDecoderAndSanitizer is AaveV3DecoderAndSanitizer {
    constructor(address _boringVault) BaseDecoderAndSanitizer(_boringVault) {}
}
