import "@nomicfoundation/hardhat-toolbox"
import { HardhatUserConfig } from "hardhat/config"
import "./tasks/deploy-imt-test"
import "dotenv/config"

const hardhatConfig: HardhatUserConfig = {
    solidity: {
        version: "0.8.36",
        settings: {
            viaIR: false,
            optimizer: {
                enabled: true,
                runs: 1000000
            }
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
