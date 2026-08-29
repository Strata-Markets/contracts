// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {SD59x18} from '@prb/math/src/sd59x18/Math.sol';
import {UD60x18} from "@prb/math/src/ud60x18/Math.sol";
import {IRiskPremiumModel} from "./IRiskPremiumModel.sol";


contract RiskPremiumSigmoid is IRiskPremiumModel {
    SD59x18 internal constant ZERO = SD59x18.wrap(0);
    SD59x18 internal constant ONE = SD59x18.wrap(1e18);

    SD59x18 public immutable pMin;
    SD59x18 public immutable pMax;
    // steepness
    SD59x18 public immutable k;
    // sigmoid midpoint
    SD59x18 public immutable sOptimal;
    // sigmoidAtZero
    SD59x18 internal immutable S0;
    // sigmoidAtOne
    SD59x18 internal immutable S1;

    constructor (
        SD59x18 pMin_,
        SD59x18 pMax_,
        SD59x18 k_,
        SD59x18 sOptimal_
    ) {
        require(ZERO <= pMin_ && pMin_ < ONE, "InvalidMin");
        require(ZERO <= pMax_ && pMax_ < ONE, "InvalidMax");
        require(ZERO <= sOptimal_ && sOptimal_ < ONE, "InvalidOptimal");
        // If min equals max, deploy a constant risk premium model instead.
        require(pMin_ < pMax_, "pMin>=pMax");
        require(k_ >= ZERO, "k<0");

        pMin = pMin_;
        pMax = pMax_;
        k = k_;
        sOptimal = sOptimal_;

        S0 = sigmoid(ZERO, k, sOptimal);
        S1 = sigmoid(ONE, k, sOptimal);
    }

    function riskPremium(UD60x18 tvlRatio) external view returns (UD60x18) {
        return riskPremiumInner(tvlRatio.intoSD59x18()).intoUD60x18();
    }

    /// Normalized: N(r) = (S(r) - S(0)) / (S(1) - S(0))
    /// Raw: S(r)
    /// @dev For now, this model uses the raw sigmoid version.
    function riskPremiumInner(SD59x18 tvlRatio) internal view returns (SD59x18) {
        SD59x18 StvlRatio = sigmoid(tvlRatio, k, sOptimal);
        // SD59x18 normalized = (StvlRatio - S0) / (S1 - S0);
        return pMin + (pMax - pMin) * StvlRatio;
    }

    /// S(r)= 1 / (1 + e ^ (−k * (r − sOptimal​)))
    function sigmoid(SD59x18 s, SD59x18 k_, SD59x18 sOptimal_) internal pure returns (SD59x18) {
        SD59x18 z = k_ * (s - sOptimal_);

        // Numerically stable implementation:
        // exp() always receives <= 0.
        if (z >= ZERO) {
            SD59x18 e = (-z).exp();
            return ONE / (ONE + e);
        } else {
            SD59x18 e = z.exp();
            return e / (ONE + e);
        }
    }

}
