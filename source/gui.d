module gui;

import sgdevice;
import sg;
import termbox;
import arguments;
import std.algorithm;
import std.range;
import std.random;
import std.format;
import std.mmfile;
import std.conv;
import std.traits;
import core.thread;

private enum BlockStatus : ubyte
{
	UNKNOWN = 0,
	READ = 'R',
	BAD = 'B',
	READING = 'O',
}

class Gui
{
	this(SGDevice device, Arguments arguments)
	{
		this.device = device;
		this.arguments = arguments;

		if (arguments.debugRun)
			capacity.blocks = 100;
		else
			capacity = device.getCapacity();

		blocks = new BlockStatus[capacity.blocks];
		blocks[] = BlockStatus.UNKNOWN;
		readBuffer = new ubyte[capacity.blockSize];

		if (arguments.output.length > 0)
		{
			outputFile = new MmFile(arguments.output, MmFile.Mode.readWrite, capacity.bytes, null);
			mapFile = new MmFile(arguments.output ~ ".map", MmFile.Mode.readWrite, blocks.length, null);

			foreach (i; 0 .. blocks.length)
				blocks[i] = cast(BlockStatus) mapFile[i];
		}

		blocksRead = cast(uint) blocks.count!(block => block == BlockStatus.READ);

		generateReadOrder();
		init();
		hideCursor();
	}

	~this()
	{
		shutdown();
	}

	void drawAll()
	{
		clear();
		foreach (i, block; blocks)
			draw(cast(uint) i);
		flush();
	}

	void mainLoop()
	{
		drawAll();
		resetDevice();
		Event e;
		while (!finished)
		{
			immutable status = peekEvent(&e, 0);
			if (status == EventType.key)
			{
				if (e.key == Key.esc)
				{
					return;
				}
			}
			else if (!finished)
			{
				drawStatus();
				executeOperation();
			}
		}

		drawStatus();
		device.reset();
		while (true)
		{
			immutable status = pollEvent(&e);
			if (status == EventType.key && e.key == Key.esc)
			{
				return;
			}
		}
	}

private:
	SGDevice device;
	MmFile outputFile = null;
	MmFile mapFile = null;
	Capacity capacity;
	ubyte[] readBuffer;
	BlockStatus[] blocks;
	uint[] readOrder;
	uint blocksRead = 0;
	uint readIndex = 0;
	uint currentBlock = 0;
	uint readAttemptsSinceLastSuccessful = 0;
	bool finished = false;
	bool seekTest;
	Arguments arguments;

	void resetDevice()
	{
		Thread.sleep(msecs(500));
		device.seek(0);
		Thread.sleep(msecs(350));
		device.reset();
	}

	void markCurrent()
	{
		draw(currentBlock, BlockStatus.READING);
	}

	void generateReadOrder()
	{
		readOrder.length = 0;
		foreach (i, state; blocks)
		{
			if (state == BlockStatus.BAD || state == BlockStatus.UNKNOWN)
			{
				readOrder ~= cast(uint) i;
			}
		}


		readOrder = readOrder.randomCover().array();
		//readOrder = readOrder.reverse().array();
	}

	void finishedReadAttempt()
	{	
		generateReadOrder();

		// We don't need to read anymore if there are no bad blocks left.
		if (readOrder.length == 0)
		{
			finished = true;
			return;
		}

		readAttemptsSinceLastSuccessful++;
		readIndex = 0;
	}

	void saveBlock(uint block, ubyte[] buffer)
	{
		if (outputFile is null)
			return;
		
		auto offset = block * 512;
		foreach (i, value; buffer)
			outputFile[i + offset] = value;
	}

	void executeOperation()
	{
		if (readIndex >= readOrder.length)
		{
			finishedReadAttempt();
			drawAll();
			return;
		}

		currentBlock = readOrder[readIndex++];
		if (blocks[currentBlock] != BlockStatus.READ)
		{
			markCurrent();
			flush();

			/*for (int i = 0; i < 5; i++)
			{*/
				if (arguments.seekTest)
					performSeekTest();
				else if (arguments.debugRun)
					performDebugRun();
				else if (arguments.format)
					performFormat();
				else
					performRead();
				
				/*if (blocks[currentBlock] == BlockStatus.READ)
					break;
			}*/
			draw(currentBlock);

			if (blocks[currentBlock] == BlockStatus.READ)
				blocksRead++;
		}

		if (mapFile !is null)
			mapFile[currentBlock] = cast(ubyte) blocks[currentBlock];

		flush();

		Thread.sleep(10.msecs);
	}

	void performRead()
	{
		try
		{
			assert(blocks[currentBlock] != BlockStatus.READ, "Reading a block that was already read");
			device.readSector10(readBuffer, currentBlock);
			blocks[currentBlock] = BlockStatus.READ;
			readAttemptsSinceLastSuccessful = 0;

			saveBlock(currentBlock, readBuffer);
		}
		catch (Exception e)
		{
			blocks[currentBlock] = BlockStatus.BAD;
			resetDevice();
		}
	}

	void performFormat()
	{
		if (blocks[currentBlock] != BlockStatus.UNKNOWN)
			return;

		auto geometry = DDGeometry;
		CHS chs = CHS(geometry, currentBlock);
		bool success = false;
		try
		{
			device.format(chs, capacity);
			success = true;
		}
		catch (Exception e)
		{
			resetDevice();
		}

		foreach (sector; 0 .. geometry.sectors_per_track)
		{
			chs.sector = sector + 1;
			uint block = chs.lba(geometry);
			blocks[block] = success ? BlockStatus.READ : BlockStatus.BAD;
			draw(block);
		}
	}

	void performSeekTest()
	{
		device.seek(currentBlock);
		Thread.sleep(msecs(150));

		blocks[currentBlock] = BlockStatus.READ;
	}

	void performDebugRun()
	{
		Thread.sleep(10.msecs);
		blocks[currentBlock] = [BlockStatus.READ, BlockStatus.BAD].choice();
	}

	void draw(uint block, BlockStatus status)
	{
		immutable uint x = block % 64;
		immutable uint y = block / 64;

		setCell(x, y, '#', getColor(status), getColor(status));
	}

	void draw(uint block)
	{
		draw(block, blocks[block]);
	}

	void drawStatus()
	{
		immutable uint y = cast(uint) (blocks.length / 64 + 2);
		putString(0, y, "                                         ");
		putString(0, y + 1, "                                         ");
		if (!finished)
		{
			putString(0, y, "Blocks read: %d / %d (%.2f%%)"
					.format(blocksRead, blocks.length, cast(float) blocksRead / blocks.length * 100));
			putString(0, y + 1, "Retries since last good: %d".format(readAttemptsSinceLastSuccessful));
		}
		else
		{
			putString(0, y, "Finished! Press ESC to exit");
		}
		flush();
	}

	void putString(uint x, uint y, string str)
	{
		foreach (i, c; str)
		{
			setCell(cast(uint) (x + i), y, c, Color.basic, Color.basic);
		}
	}

	Color getColor(BlockStatus status) pure
	{
		final switch (status)
		{
			case BlockStatus.UNKNOWN:
				return Color.white;
			case BlockStatus.READ:
				return Color.green;
			case BlockStatus.BAD:
				return Color.red;
			case BlockStatus.READING:
				return Color.magenta;
		}
	}
}