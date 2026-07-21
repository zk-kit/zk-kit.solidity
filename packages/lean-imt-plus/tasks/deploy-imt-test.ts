import { task, types } from "hardhat/config"

task("deploy:imt-plus-test", "Deploy a LeanIMTPlus test contract for testing the library")
    .addOptionalParam<boolean>("logs", "Print the logs", true, types.boolean)
    .setAction(async ({ logs }, { ethers }): Promise<any> => {
        // LeanIMTPlus commits leaves with a 3-input Poseidon hash (PoseidonT4) and
        // internal nodes with a 2-input Poseidon hash (PoseidonT3), so both must be
        // deployed and linked.
        const PoseidonT3Factory = await ethers.getContractFactory("PoseidonT3")
        const poseidonT3 = await PoseidonT3Factory.deploy()
        const poseidonT3Address = await poseidonT3.getAddress()

        if (logs) {
            console.info(`PoseidonT3 library has been deployed to: ${poseidonT3Address}`)
        }

        const PoseidonT4Factory = await ethers.getContractFactory("PoseidonT4")
        const poseidonT4 = await PoseidonT4Factory.deploy()
        const poseidonT4Address = await poseidonT4.getAddress()

        if (logs) {
            console.info(`PoseidonT4 library has been deployed to: ${poseidonT4Address}`)
        }

        const LibraryFactory = await ethers.getContractFactory("LeanIMTPlus", {
            libraries: {
                PoseidonT3: poseidonT3Address,
                PoseidonT4: poseidonT4Address
            }
        })

        const library = await LibraryFactory.deploy()
        const libraryAddress = await library.getAddress()

        if (logs) {
            console.info(`LeanIMTPlus library has been deployed to: ${libraryAddress}`)
        }

        const ContractFactory = await ethers.getContractFactory("LeanIMTPlusTest", {
            libraries: {
                LeanIMTPlus: libraryAddress
            }
        })

        const contract = await ContractFactory.deploy()
        const contractAddress = await contract.getAddress()

        if (logs) {
            console.info(`LeanIMTPlusTest contract has been deployed to: ${contractAddress}`)
        }

        return { library, contract }
    })
