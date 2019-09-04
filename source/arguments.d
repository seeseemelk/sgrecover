module arguments;
import clid;
import clid.validate;
import std.stdio;

bool exists(string arg, string str)
{
	import std.file : exists;
	if (!str.exists())
	{
		stderr.writeln("Device " ~ arg ~ " must exist");
		return false;
	}
	return true;
}

struct Arguments
{
	@Parameter("device", 'd')
	@Description("The sg device to use", "DEVICE")
	@Required
	@Validate!exists
	string device;

	@Parameter("output", 'o')
	@Description("Output file when reading", "FILE")
	string output;

	@Parameter("read", 'r')
	@Description("Read all data of the current media")
	bool read;

	@Parameter("seek", 's')
	@Description("Perform a seek test")
	bool seekTest;

	@Parameter("debug")
	@Description("Performs a debug run, has no value to an end-user")
	bool debugRun;

	@Parameter("format")
	@Description("Formats a disk")
	bool format;
}