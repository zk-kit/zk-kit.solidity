import { task, types } from "hardhat/config"

task("deploy:imt-sha256-test", "Deploy a LeanIMTSha256 test contract for testing the library")
    .addOptionalParam<boolean>("logs", "Print the logs", true, types.boolean)
    .setAction(async ({ logs }, { ethers }): Promise<any> => {
        // SHA-256 is a precompile: no hash libraries to deploy or link.
        const LibraryFactory = await ethers.getContractFactory("LeanIMTSha256")

        const library = await LibraryFactory.deploy()
        const libraryAddress = await library.getAddress()

        if (logs) {
            console.info(`LeanIMTSha256 library has been deployed to: ${libraryAddress}`)
        }

        const ContractFactory = await ethers.getContractFactory("LeanIMTSha256Test", {
            libraries: {
                LeanIMTSha256: libraryAddress
            }
        })

        const contract = await ContractFactory.deploy()
        const contractAddress = await contract.getAddress()

        if (logs) {
            console.info(`LeanIMTSha256Test contract has been deployed to: ${contractAddress}`)
        }

        return { library, contract }
    })
