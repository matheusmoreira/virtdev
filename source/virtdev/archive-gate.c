#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

enum {
	gate_invalid = 2,
	gate_budget = 3,
	gate_usage = 64,
	tar_block_size = 512
};

struct tar_header {
	unsigned char name[100];
	unsigned char mode[8];
	unsigned char uid[8];
	unsigned char gid[8];
	unsigned char size[12];
	unsigned char mtime[12];
	unsigned char checksum[8];
	unsigned char type;
	unsigned char linkname[100];
	unsigned char magic[6];
	unsigned char version[2];
	unsigned char uname[32];
	unsigned char gname[32];
	unsigned char devmajor[8];
	unsigned char devminor[8];
	unsigned char prefix[155];
	unsigned char padding[12];
};

typedef char tar_header_must_be_one_block[
	sizeof(struct tar_header) == tar_block_size ? 1 : -1];

static int
parse_limit(const char *text, uint64_t *result)
{
	char *end = NULL;
	unsigned long long value;

	errno = 0;
	value = strtoull(text, &end, 10);
	if (errno != 0 || end == text || *end != '\0' || value == 0)
		return -1;
	*result = (uint64_t)value;
	return 0;
}

static int
read_exact(int fd, void *buffer, size_t length)
{
	unsigned char *cursor = buffer;

	while (length > 0) {
		ssize_t count = read(fd, cursor, length);
		if (count == 0)
			return -1;
		if (count < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		cursor += (size_t)count;
		length -= (size_t)count;
	}
	return 0;
}

static int
all_zero(const unsigned char *block)
{
	size_t index;

	for (index = 0; index < tar_block_size; ++index) {
		if (block[index] != 0)
			return 0;
	}
	return 1;
}

static int
remaining_zero(int fd, uint64_t remaining)
{
	unsigned char buffer[4096];

	while (remaining > 0) {
		size_t wanted = remaining < sizeof(buffer) ?
		    (size_t)remaining : sizeof(buffer);
		size_t index;

		if (read_exact(fd, buffer, wanted) != 0)
			return 0;
		for (index = 0; index < wanted; ++index) {
			if (buffer[index] != 0)
				return 0;
		}
		remaining -= wanted;
	}
	return 1;
}

static int
parse_octal(const unsigned char *field, size_t length, uint64_t *result)
{
	size_t index = 0;
	uint64_t value = 0;
	int found = 0;

	while (index < length && (field[index] == ' ' || field[index] == '\0'))
		++index;
	for (; index < length; ++index) {
		unsigned char byte = field[index];
		if (byte == '\0' || byte == ' ')
			break;
		if (byte < '0' || byte > '7' || value > (UINT64_MAX >> 3))
			return -1;
		value = (value << 3) | (uint64_t)(byte - '0');
		found = 1;
	}
	while (index < length) {
		if (field[index] != '\0' && field[index] != ' ')
			return -1;
		++index;
	}
	if (!found)
		value = 0;
	*result = value;
	return 0;
}

static int
parse_tar_number(const unsigned char *field, size_t length, uint64_t *result)
{
	size_t index;
	uint64_t value;

	if ((field[0] & 0x80U) == 0)
		return parse_octal(field, length, result);
	if ((field[0] & 0x40U) != 0)
		return -1;
	value = field[0] & 0x3fU;
	for (index = 1; index < length; ++index) {
		if (value > (UINT64_MAX >> 8))
			return -1;
		value = (value << 8) | field[index];
	}
	*result = value;
	return 0;
}

static int
header_checksum_valid(const unsigned char *block)
{
	const struct tar_header *header = (const struct tar_header *)block;
	uint64_t expected;
	uint64_t sum = 0;
	size_t index;

	if (parse_octal(header->checksum, sizeof(header->checksum), &expected) != 0)
		return 0;
	for (index = 0; index < tar_block_size; ++index) {
		if (index >= 148 && index < 156)
			sum += (unsigned char)' ';
		else
			sum += block[index];
	}
	return sum == expected;
}

static size_t
find_byte_index(const unsigned char *field, size_t length, unsigned char byte)
{
	size_t index;

	for (index = 0; index < length; ++index) {
		if (field[index] == byte)
			return index;
	}
	return length;
}

static size_t
field_length(const unsigned char *field, size_t maximum)
{
	return find_byte_index(field, maximum, '\0');
}

static int
header_paths_fit(const struct tar_header *header, uint64_t maximum)
{
	uint64_t name_length = field_length(header->name, sizeof(header->name));
	uint64_t prefix_length = field_length(header->prefix,
	    sizeof(header->prefix));
	uint64_t link_length = field_length(header->linkname,
	    sizeof(header->linkname));

	if (prefix_length > 0) {
		if (name_length > UINT64_MAX - prefix_length - 1)
			return 0;
		name_length += prefix_length + 1;
	}
	return name_length <= maximum && link_length <= maximum;
}

static int
pax_key_is_path(const unsigned char *key, size_t length)
{
	static const char *const names[] = {
		"path", "linkpath", "GNU.sparse.name", "SCHILY.linkpath"
	};
	size_t index;

	for (index = 0; index < sizeof(names) / sizeof(names[0]); ++index) {
		size_t name_length = strlen(names[index]);
		if (length == name_length && memcmp(key, names[index], length) == 0)
			return 1;
	}
	return 0;
}

static int
validate_pax(const unsigned char *data, size_t size, uint64_t path_maximum)
{
	size_t position = 0;

	while (position < size) {
		size_t cursor = position;
		size_t record_length = 0;
		size_t record_end;
		size_t equals_index;

		if (data[cursor] < '1' || data[cursor] > '9')
			return -1;
		while (cursor < size && data[cursor] >= '0' && data[cursor] <= '9') {
			if (record_length > (SIZE_MAX - 9) / 10)
				return -1;
			record_length = record_length * 10 + (size_t)(data[cursor] - '0');
			++cursor;
		}
		if (cursor >= size || data[cursor] != ' ' || record_length == 0
		    || record_length > size - position)
			return -1;
		record_end = position + record_length;
		if (data[record_end - 1] != '\n' || cursor + 1 >= record_end - 1)
			return -1;
		equals_index = find_byte_index(data + cursor + 1,
		    record_end - 1 - (cursor + 1), '=');
		if (equals_index == 0
		    || equals_index == record_end - 1 - (cursor + 1))
			return -1;
		if (pax_key_is_path(data + cursor + 1,
		    equals_index)) {
			size_t value_start = cursor + 1 + equals_index + 1;
			size_t value_length = record_end - 1 - value_start;
			if ((uint64_t)value_length > path_maximum
			    || find_byte_index(data + value_start, value_length, '\0')
			    != value_length)
				return 1;
		}
		position = record_end;
	}
	return 0;
}

static int
skip_payload(int fd, uint64_t size, uint64_t file_size, uint64_t *offset)
{
	uint64_t padded;

	if (size > UINT64_MAX - (tar_block_size - 1))
		return -1;
	padded = (size + tar_block_size - 1) & ~(uint64_t)(tar_block_size - 1);
	if (padded > file_size - *offset || padded > (uint64_t)INT64_MAX)
		return -1;
	if (lseek(fd, (off_t)padded, SEEK_CUR) < 0)
		return -1;
	*offset += padded;
	return 0;
}

int
main(int argc, char **argv)
{
	uint64_t entry_maximum, path_maximum, extension_maximum;
	uint64_t file_size, offset = 0, members = 0, extensions = 0;
	uint64_t extension_count_maximum;
	unsigned char block[tar_block_size];
	struct stat status;
	int fd, zero_blocks = 0;

	if (argc != 5
	    || parse_limit(argv[2], &entry_maximum) != 0
	    || parse_limit(argv[3], &path_maximum) != 0
	    || parse_limit(argv[4], &extension_maximum) != 0)
		return gate_usage;
	if (entry_maximum > (UINT64_MAX - 16) / 3)
		return gate_usage;
	extension_count_maximum = entry_maximum * 3 + 16;
	fd = open(argv[1], O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	if (fd < 0)
		return gate_invalid;
	if (fstat(fd, &status) != 0 || !S_ISREG(status.st_mode)
	    || status.st_size < 0) {
		close(fd);
		return gate_invalid;
	}
	file_size = (uint64_t)status.st_size;

	while (offset < file_size) {
		struct tar_header *header = (struct tar_header *)block;
		uint64_t payload_size;
		int extension = 0;

		if (file_size - offset < tar_block_size
		    || read_exact(fd, block, sizeof(block)) != 0) {
			close(fd);
			return gate_invalid;
		}
		offset += tar_block_size;
		if (all_zero(block)) {
			if (++zero_blocks == 2) {
				int valid = remaining_zero(fd, file_size - offset);

				close(fd);
				return valid ? 0 : gate_invalid;
			}
			continue;
		}
		zero_blocks = 0;
		if (!header_checksum_valid(block)
		    || parse_tar_number(header->size, sizeof(header->size),
		    &payload_size) != 0
		    || !header_paths_fit(header, path_maximum)) {
			close(fd);
			return gate_invalid;
		}

		if (header->type == 'L' || header->type == 'K') {
			unsigned char *value;
			if (payload_size > path_maximum + 1
			    || payload_size > (uint64_t)SIZE_MAX) {
				close(fd);
				return gate_budget;
			}
			value = malloc(payload_size == 0 ? 1 : (size_t)payload_size);
			if (value == NULL
			    || read_exact(fd, value, (size_t)payload_size) != 0) {
				free(value);
				close(fd);
				return gate_invalid;
			}
			offset += payload_size;
			{
				size_t length = find_byte_index(value,
				    (size_t)payload_size, '\0');
				if ((uint64_t)length > path_maximum) {
					free(value);
					close(fd);
					return gate_budget;
				}
			}
			free(value);
			payload_size = 0;
			extension = 1;
		} else if (header->type == 'x' || header->type == 'g') {
			unsigned char *pax;
			int pax_status;
			if (payload_size > extension_maximum
			    || payload_size > (uint64_t)SIZE_MAX) {
				close(fd);
				return gate_budget;
			}
			pax = malloc(payload_size == 0 ? 1 : (size_t)payload_size);
			if (pax == NULL
			    || read_exact(fd, pax, (size_t)payload_size) != 0) {
				free(pax);
				close(fd);
				return gate_invalid;
			}
			offset += payload_size;
			pax_status = validate_pax(pax, (size_t)payload_size,
			    path_maximum);
			free(pax);
			if (pax_status != 0) {
				close(fd);
				return pax_status > 0 ? gate_budget : gate_invalid;
			}
			payload_size = 0;
			extension = 1;
		}

		if (extension) {
			uint64_t remainder = offset % tar_block_size;
			uint64_t padding = remainder == 0 ? 0 : tar_block_size - remainder;
			if (padding > file_size - offset || lseek(fd, (off_t)padding,
			    SEEK_CUR) < 0 || ++extensions > extension_count_maximum) {
				close(fd);
				return gate_budget;
			}
			offset += padding;
			continue;
		}

		if (++members > entry_maximum
		    || skip_payload(fd, payload_size, file_size, &offset) != 0) {
			close(fd);
			return members > entry_maximum ? gate_budget : gate_invalid;
		}
	}
	close(fd);
	return gate_invalid;
}
