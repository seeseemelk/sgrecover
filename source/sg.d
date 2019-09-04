module sg;

/// IOCTL number for SG io operation.
enum IOCTL : int
{
	IO = 0x2285,
	RESET = 0x2284,
}

/// Data transfer direction.
enum SGDirection : int
{
	/// e.g. a SCSI Test Unit Ready command
	SG_DXFER_NONE = -1,
	
	/// e.g. a SCSI WRITE command
	SG_DXFER_TO_DEV = -2,
	
	/// e.g. a SCSI READ command
	SG_DXFER_FROM_DEV = -3,

	/// treated like SG_DXFER_FROM_DEV with the
	/// additional property than during indirect
	///IO the user buffer is copied into the
	///kernel buffers before the transfer
	SG_DXFER_TO_FROM_DEV = -4,
}

/// Possible status codes for `sh_io_hdr.masked_status`.
enum Status : ubyte
{
	GOOD = 0,
	RECOVERED = 1,
	ERROR = 0xFF,
	UNFORMMATTED_MEDIA = 1,
	FORMATTED_MEDIA = 2,
	NO_MEDIA = 3,
	PROTECTED = 1,
	NOT_PROTECTED = 0,
}

enum MaskedStatus : ubyte
{
	GOOD = 0x0,
	CHECK_CONDITION = 0x1,
	CONDITION_GOOD = 0x2,
	BUSY = 0x4,
	INTERMEDIATE_GOOD = 0x8,
	INTERMEDIATE_C_GOOD = 0xA,
	RESERVATION_CONFLICT = 0xC,
	COMMAND_TERMINATED = 0x11,
	QUEUE_FULL = 0x14,
}

enum ResetTarget
{
	TARGET = 0x4,
	BUS = 0x2,
}

struct sg_io_hdr
{
	int interface_id;           /** [i] 'S' for SCSI generic (required) */
	int dxfer_direction;        /** [i] data transfer direction  */
	ubyte cmd_len;      /** [i] SCSI command length ( <= 16 bytes) */
	ubyte mx_sb_len;    /** [i] max length to write to sbp */
	ushort iovec_count; /** [i] 0 implies no scatter gather */
	uint dxfer_len;     /** [i] byte count of data transfer */
	void* dxferp;              /** [i], [*io] points to data transfer memory or scatter gather list */
	const(ubyte)* cmdp;       /** [i], [*i] points to command to perform */
	ubyte* sbp;        /** [i], [*o] points to sense_buffer memory */
	uint timeout;       /** [i] MAX_UINT->no timeout (unit: millisec) */
	uint flags;         /** [i] 0 -> default, see SG_FLAG... */
	int pack_id;                /** [i->o] unused internally (normally) */
	void* usr_ptr;             /** [i->o] unused internally */
	ubyte status;       /** [o] scsi status */
	MaskedStatus masked_status;/** [o] shifted, masked scsi status */
	ubyte msg_status;   /** [o] messaging level data (optional) */
	ubyte sb_len_wr;    /** [o] byte count actually written to sbp */
	ushort host_status; /** [o] errors from host adapter */
	ushort driver_status;/** [o] errors from software driver */
	int resid;                  /** [o] dxfer_len - actual_transferred */
	uint duration;      /** [o] time taken by cmd (unit: millisec) */
	uint info;          /** [o] auxiliary information */
}

struct Packet
{
	sg_io_hdr hdr;
	ubyte[32] sense_buffer;
}

struct Capacity
{
	uint blocks;
	uint blockSize;

	this(uint blocks, uint blockSize)
	{
		this.blocks = blocks;
		this.blockSize = blockSize;
	}

	ulong bytes() const
	{
		return blocks * blockSize;
	}
}

struct Geometry
{
	uint heads;
	uint tracks;
	uint sectors_per_track;

	this(uint heads, uint tracks, uint sectors_per_track)
	{
		this.heads = heads;
		this.tracks = tracks;
		this.sectors_per_track = sectors_per_track;
	}
}

enum DDGeometry = Geometry(2, 80, 9);
enum HDGeometry = Geometry(2, 80, 18);

struct CHS
{
	uint track;
	uint head;
	uint sector;

	this(Geometry geometry, uint lba)
	{
		sector = (lba % geometry.sectors_per_track) + 1;
		head = (lba / geometry.sectors_per_track) % geometry.heads;
		track = (lba / geometry.sectors_per_track) / geometry.heads;
	}

	uint lba(Geometry geometry)
	{
		return (((track * geometry.heads) + head) * geometry.sectors_per_track) + (sector - 1);
	}
}
