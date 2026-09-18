#pragma once
// Minimal replacement for 3Dmigoto's util.h, which otherwise pulls in the whole
// D3D11 runtime (HookedDevice.h etc.). cmd_Decompiler only needs BinaryToAsmText
// and the logging helpers already provided by log.h.
#include <string>
#include <vector>
#include "log.h"
#include "shader.h"
#include "version.h"

using namespace std;

// Flugan's disassembler wrapper: prints floats with %.9e so 32-bit values are
// reproduced exactly (MS's D3DDisassemble uses %f and loses precision).
static string BinaryToAsmText(const void *pShaderBytecode, size_t BytecodeLength,
                              bool patch_cb_offsets,
                              bool disassemble_undecipherable_data = true,
                              int hexdump = 0, bool d3dcompiler_46_compat = true)
{
	string comments;
	vector<byte> byteCode(BytecodeLength);
	vector<byte> disassembly;

	comments = "//   using 3Dmigoto v" + string(VER_FILE_VERSION_STR) + " on " + LogTime() + "//\n";
	memcpy(byteCode.data(), pShaderBytecode, BytecodeLength);

	HRESULT r = disassembler(&byteCode, &disassembly, comments.c_str(), hexdump,
	                         d3dcompiler_46_compat, disassemble_undecipherable_data, patch_cb_offsets);
	if (FAILED(r)) {
		LogInfo("  disassembly failed. Error: %x\n", r);
		return "";
	}
	return string(disassembly.begin(), disassembly.end());
}
