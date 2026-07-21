import "@nomicfoundation/hardhat-toolbox"
import { HardhatUserConfig } from "hardhat/config"
import "./tasks/deploy-imt-test"
import "dotenv/config"

const hardhatConfig: HardhatUserConfig = {
    solidity: {
        // LeanIMTPlus is compiled with the latest solc + `viaIR`. The other packages
        // target 0.8.23, but that compiler's IR pipeline is pathologically slow on the
        // Poseidon assembly; recent compilers are not.
        version: "0.8.36",
        settings: {
            // `viaIR` is required: without the IR pipeline the batched `_recompute`
            // in InternalLeanIMTPlus hits "stack too deep".
            viaIR: true,
            optimizer: {
                enabled: true,
                runs: 200
            }
        }
    },
    networks: {
        // The Poseidon libraries compile to > 24 KB. The EIP-170 size limit is a
        // mainnet concern (on-chain they are deployed via a deterministic proxy) and
        // must be lifted for the local test/coverage network.
        hardhat: {
            allowUnlimitedContractSize: true
        }
    },
    gasReporter: {
        currency: "USD",
        enabled: process.env.REPORT_GAS === "true",
        outputJSONFile: "gas-report-leanimtplus.json",
        outputJSON: process.env.REPORT_GAS_OUTPUT_JSON === "true"
    },
    typechain: {
        target: "ethers-v6"
    }
}

export default hardhatConfig
