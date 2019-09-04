module sgdevice;

import sg;
import std.stdio;
import std.file;
import core.sys.posix.sys.ioctl;
import std.datetime;
import std.bitmanip;

MaskedStatus status(ref Packet packet)
{
	return packet.hdr.masked_status;
}

ubyte senseKey(ref Packet packet)
{
	return packet.sense_buffer[2];
}

ubyte senseASC(ref Packet packet)
{
	return packet.sense_buffer[12];
}

ubyte senseASCQ(ref Packet packet)
{
	return packet.sense_buffer[13];
}

/// An SG device
class SGDevice
{
	/// Creates a new SG device.
	this(string device)
	{
		this.file = File(device, "w");
	}

	/// Invokes an SG command on a device.
	/// Params:
	/// 	packet = The packet buffer to use.
	/// 		This buffer will contain some error information after
	/// 		the command was executed.
	/// 	command = The command to execute.
	/// 	data = A buffer containing data to send or to receive.
	/// 	direction = The data transfer direction.
	void invoke(ref Packet packet, const ubyte[] command, ubyte[] data, SGDirection direction)
	in(command.length <= 16)
	{
		packet.hdr.interface_id = 'S';
		packet.hdr.cmdp = command.ptr;
		packet.hdr.cmd_len = cast(ubyte) command.length;
		packet.hdr.dxfer_direction = direction;
		packet.hdr.dxferp = data.ptr;
		packet.hdr.dxfer_len = cast(uint) data.length;
		packet.hdr.sbp = packet.sense_buffer.ptr;
		packet.hdr.mx_sb_len = packet.sense_buffer.length;
		packet.hdr.timeout = cast(uint) seconds(10).total!"msecs";

		if (ioctl(file.fileno, IOCTL.IO, &packet.hdr) < 0)
		{
			throw new FileException("IOCTL failed");
		}
	}

	/// Invokes a command without a data buffer.
	void invoke(ref Packet packet, const ubyte[] command)
	{
		invoke(packet, command, [], SGDirection.SG_DXFER_TO_DEV);
	}

	/// Log errors in a packet, if any occured.
	void logError(ref Packet packet, string msg)
	{
		if (packet.hdr.masked_status != MaskedStatus.GOOD)
		{
			stderr.writefln!"SCSI error(command=0x%02X, status=0x%02X, sense=0x%02X, asc=0x%02X, ascq=0x%02X) %s"
					(packet.hdr.cmdp[0], packet.hdr.masked_status, packet.senseKey, packet.senseASC, packet.senseASCQ, msg);
		}
	}

	/// Log errors in a packet, if any occured.
	void logError(ref Packet packet)
	{
		logError(packet, "");
	}

	/// Checks whether the unit is ready to perform operations
	/// on a media.
	/// Returns: `true` when the device is ready, `false` when
	/// 	the device is not yet ready.
	bool isUnitReady()
	{
		Packet packet;
		static immutable ubyte[] command = [
			0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		];
		invoke(packet, command);
		if (packet.status == 1)
		{
			immutable sk = packet.senseKey;
			immutable asc = packet.senseASC;
			immutable ascq = packet.senseASCQ;
			if (sk == 2 && asc == 0x3a && ascq == 0) {
				logError(packet, "Medium not present");
			} else {
				logError(packet);
			}
			return false;
		}
		else if (packet.status == 0)
		{
			return true;
		}
		return false;
	}

	/// Attempts to reset the device.
	void reset()
	{
		// This seems like it could be wrong,
		// but it is a direct port of
		// https://github.com/tedigh/ufiformat/blob/master/ufi_command.c
		// Maybe upstream has a bug?
		int mode = ResetTarget.TARGET;
		if (ioctl(file.fileno, IOCTL.RESET, &mode) < 0) {
			mode = ResetTarget.BUS;
			if (ioctl(file.fileno, IOCTL.RESET, &mode) < 0) {
				throw new Exception("Failed to reset device");
			}
		}

		// Wait for the device to intialise itself.
		for (;;)
		{
			Packet packet;
			static immutable ubyte[] command = [
				0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
				0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			];
			invoke(packet, command);
			immutable sk = packet.senseKey;
			immutable asc = packet.senseASC;
			immutable ascq = packet.senseASCQ;
			if (sk != 2 || asc != 0x3A || (ascq != 0x28 && asc != 0x29))
				break;
		}
	}

	Capacity getCapacity()
	{
		static immutable ubyte[] command = [
			0x25, // Opcode
			0x00, // RelAdr
			0x00, 0x00, 0x00, 0x00, // LBA (zero)
			0x00, 0x00, 0x00, 0x00, 0x00, 0x00 // Reserved
		];
		ubyte[8] data;
		Packet packet;
		invoke(packet, command, data, SGDirection.SG_DXFER_FROM_DEV);

		if (packet.senseKey != 0) {
			logError(packet);
			throw new Exception("Could not read capacity");
		}

		immutable lba = data[].peek!(uint, Endian.bigEndian)(0) + 1;
		immutable blockSize = data[].peek!uint(4);
		return Capacity(lba, blockSize);
	}

	Capacity[] getFormattableCapacities()
	{
		ubyte[3 + 7 + 7 * 10] data;
		static immutable ubyte[] command = [
			0x23, // OpCode
			0x00, // Device
			0x00, 0x00, 0x00, 0x00, 0x00, // Reserved
			cast(ubyte) (data.length >> 8), // Data buffer size
			cast(ubyte) data.length,
			0x00, 0x00, 0x00 // Reserved
		];
		Packet packet;
		invoke(packet, command, data, SGDirection.SG_DXFER_FROM_DEV);

		immutable listEntries = data[3] / 8;

		Capacity[] capacities = new Capacity[listEntries];
		foreach (i; 0 .. listEntries)
		{
			immutable offset = i * 8 + 4;
			immutable numBlocks = data[].peek!uint(offset) + 1;
			immutable blockSize = data[].peek!uint(offset + 4) & 0x00FF_FFFF;
			
			capacities[i] = Capacity(numBlocks, blockSize);
		}

		return capacities;
	}

	void readSector12(ref ubyte[] output, uint lba)
	in (output.length % 512 == 0)
	{
		ubyte[] command = [
			0xA8, // Opcode
			0x20, // Device
			0x00, 0x00, 0x00, 0x00, // LBA
			0x00, 0x00, 0x00, 0x00, // Transfer length
			0x00, 0x00, // Reserved
		];

		command.write!uint(lba, 2);
		command.write!uint(cast(uint) output.length / 512, 6);

		Packet packet;
		invoke(packet, command, output, SGDirection.SG_DXFER_FROM_DEV);

		if (packet.status != MaskedStatus.GOOD)
		{
			throw new Exception("Failed to read from device");
		}
	}

	void readSector10(ubyte[] output, uint lba)
	in (output.length % 512 == 0)
	{
		ubyte[] command = [
			0x28, // Opcode
			0x00, // Device
			0x00, 0x00, 0x00, 0x00, // LBA
			0x00, // Reserved
			0x00, 0x00, // Transfer length
			0x00, 0x00, 0x00 // Reserved
		];

		command.write!uint(lba, 2);
		command.write!ushort(cast(ushort) 1, 7);

		Packet packet;
		invoke(packet, command, output, SGDirection.SG_DXFER_FROM_DEV);

		if (packet.status != MaskedStatus.GOOD
			|| (packet.senseKey != Status.GOOD && packet.senseKey != Status.RECOVERED)
			|| packet.hdr.host_status != 0
			|| packet.hdr.driver_status != 0)
		{
			throw new Exception("Failed to read from device");
		}
	}

	void seek(uint lba)
	{
		ubyte[] command = [
			0x28, // Opcode
			0x00, // Device
			0x00, 0x00, 0x00, 0x00, // LBA
			0x00, // Reserved
			0x00, 0x00, // Transfer length
			0x00, 0x00, 0x00 // Reserved
		];

		command.write!uint(lba, 2);

		Packet packet;
		invoke(packet, command);

		if (packet.status != MaskedStatus.GOOD || packet.senseKey != Status.GOOD || packet.hdr.host_status != 0 || packet.hdr.driver_status != 0)
		{
			throw new Exception("Failed to read from device");
		}
	}

	void start()
	{
		static immutable ubyte[] command = [
			0x1B,
			0x00,
			0x00, 0x00,
			0x01,
			0x00,
			0x00, 0x00, 0x00, 0x00, 0x00, 0x00
		];

		Packet packet;
		invoke(packet, command);
	}

	void rezero()
	{
		static immutable ubyte[] command = [
			0x01, // Opcode
			0x00, 0x00, 0x00, 0x00, 0x00, // Reserved
			0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // Reserved
		];

		Packet packet;
		invoke(packet, command);
	}

	void format(CHS chs, Capacity capacity)
	{
		ubyte[] command = [
			0x04, // Opcode
			0x17, // Some parameters
			0x00, // Track number
			0x00, 0x00, // Interleave
			0x00, 0x00, // Reserved
			0x00, 0x0C, // Parameter list length
			0x00, 0x00, 0x00 // Reserved
		];

		ubyte[] data = [
			0x00, // Reserved
			0xB0, // Options
			0x00, 0x08, //Defect list length
			0x00, 0x00, 0x00, 0x00, // Number of blocks
			0x00, // Reserved
			0x00, 0x00, 0x00 // Block Length
		];

		data.write!uint(capacity.blocks, 4);
		data.write!uint(capacity.blockSize & 0x00FF_FFFF, 8);

		data[0] |= chs.head;
		command[2] = cast(ubyte) chs.track;

		Packet packet;
		invoke(packet, command, data, SGDirection.SG_DXFER_TO_DEV);

		if (packet.status != MaskedStatus.GOOD
			|| (packet.senseKey != Status.GOOD && packet.senseKey != Status.RECOVERED)
			|| packet.hdr.host_status != 0
			|| packet.hdr.driver_status != 0)
		{
			throw new Exception("Failed to format track");
		}
	}

private:
	File file;
}