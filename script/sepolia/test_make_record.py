"""Unit tests for make_record (standard library only).

Run: python -m unittest discover -s script/sepolia -p "test_*.py"
"""
import unittest

import make_record

# Round r6 on Sepolia: the deployer's factory, the salt of its first `create` call and the
# contract that call created (the governance configurator).
FACTORY = "0x2eA11C9B1222509de6dca86f38D635Bd8872B2E9"
SALT = "0xee0080ad27f812f93d7048e5bb8f823e230556f8e5bd07fa8d4d31af3b49224e"
CONFIGURATOR = "0x63BB1058C8b947C8a8a4093a43f4Ce7CCc942f44"


class CreatedBy(unittest.TestCase):
    def test_the_factorys_address_for_a_salt(self):
        self.assertEqual(make_record.created_by(FACTORY, SALT), CONFIGURATOR.lower())

    def test_another_salt_gives_another_address(self):
        other = "0x" + "11" * 32
        self.assertNotEqual(make_record.created_by(FACTORY, other), CONFIGURATOR.lower())


class Checksum(unittest.TestCase):
    def test_eip55(self):
        self.assertEqual(make_record.checksum(CONFIGURATOR.lower()), CONFIGURATOR)
        self.assertEqual(make_record.checksum(FACTORY.lower()[2:]), FACTORY)


class Flat(unittest.TestCase):
    def test_only_name_to_address_entries_are_contracts(self):
        record = {
            "Stream6529": "0xB732Ed206B8548e383Ce4481FfE03C0e7a639ebE",
            "deployer": "0x26A3f4505145b5E6164260cc868e50ddd9863697",
            "delegation": "0x8f86c644f845A077999939C69Bc787662377d915",
            "forkBlock": 12193720,
            "chainId": 11155111,
            "instance": "sepolia-r6",
            "namespace": "0x682d72056f6ad790cd349c74501ad1f739b07c3efebc910d87f2892e63b6f6e0",
            "contracts": {"Stream6529": {"address": "0xB732Ed206B8548e383Ce4481FfE03C0e7a639ebE"}},
        }
        self.assertEqual(
            make_record.flat(record), {"Stream6529": "0xB732Ed206B8548e383Ce4481FfE03C0e7a639ebE"}
        )


class Creations(unittest.TestCase):
    def test_a_call_to_create_is_mapped_by_its_salt(self):
        run = {
            "transactions": [
                {"hash": "0xa", "transactionType": "CREATE2", "contractAddress": FACTORY.lower(),
                 "function": None, "arguments": [], "additionalContracts": []},
                {"hash": "0xb", "transactionType": "CALL", "contractAddress": FACTORY.lower(),
                 "function": "create(bytes32,bytes)", "arguments": [SALT, "0x"], "additionalContracts": []},
                {"hash": "0xc", "transactionType": "CALL", "contractAddress": CONFIGURATOR.lower(),
                 "function": "configure(bytes)", "arguments": ["0x"], "additionalContracts": []},
            ],
            "receipts": [
                {"transactionHash": "0xa", "blockNumber": "0x10"},
                {"transactionHash": "0xb", "blockNumber": "0x11"},
                {"transactionHash": "0xc", "blockNumber": "0x13"},
            ],
        }
        made, blocks = make_record.creations(run)
        self.assertEqual(made, {FACTORY.lower(): ("0xa", 16), CONFIGURATOR.lower(): ("0xb", 17)})
        self.assertEqual(blocks, [16, 17, 19])


if __name__ == "__main__":
    unittest.main()
