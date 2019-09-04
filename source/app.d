import sgdevice;
import sg : Capacity;
import gui;
import arguments;
import std.stdio;
import clid;

private:

void printCapacity(Capacity capacity)
{
	ulong kib = capacity.bytes / 1024;
	double mib = kib / 1024.0;
	writefln(" %d bytes, %d KiB, %.2f MiB (block size: %d bytes)", capacity.bytes, kib, mib, capacity.blockSize);
}

void main()
{
	immutable arguments = parseArguments!Arguments();

	auto device = new SGDevice(arguments.device);
	//device.reset();
	if (!device.isUnitReady)
	{
		writeln("Device is not ready");
		return;
	}
	
	writeln("Device is ready");

	writeln("Device capacity:");
	auto capacity = device.getCapacity();
	printCapacity(capacity);

	writeln("Formattable capacities:");
	auto capacities = device.getFormattableCapacities();
	foreach (formattableCapacity; capacities)
		formattableCapacity.printCapacity();

	if (arguments.read
		|| arguments.seekTest
		|| arguments.debugRun
		|| arguments.format)
	{
		writeln("Press enter to start reading");
		readln();

		scope gui = new Gui(device, arguments);

		scope(exit) device.reset();
		gui.mainLoop();
	}
}
