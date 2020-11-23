import sys

with open(sys.argv[1], "rb") as f:
    byte = f.read(2)
    while byte != b"":
        print("".join("%02x%02x" % (byte[0], byte[1])))
        byte = f.read(2)
