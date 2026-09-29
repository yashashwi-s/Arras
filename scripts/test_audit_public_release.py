"""Pure format tests for the release-audit Mach-O parser."""

from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))

from audit_public_release import macho_architectures


class MachOTests(unittest.TestCase):
    def test_reads_universal_arm_and_intel_binary(self):
        binary = struct.pack(">II", 0xCAFEBABE, 2)
        binary += struct.pack(">IIIII", 0x0100000C, 0, 0, 0, 0)
        binary += struct.pack(">IIIII", 0x01000007, 0, 0, 0, 0)
        self.assertEqual(macho_architectures(binary), ["arm64", "x86_64"])

    def test_reads_thin_arm_binary(self):
        self.assertEqual(macho_architectures(struct.pack(">II", 0xFEEDFACF, 0x0100000C)), ["arm64"])

    def test_rejects_non_macho_data(self):
        with self.assertRaisesRegex(ValueError, "unrecognized Mach-O"):
            macho_architectures(b"not-a-mach-o")


if __name__ == "__main__":
    unittest.main()
