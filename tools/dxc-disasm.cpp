/*
 * Disassemble a shader with the DXC API (IDxcCompiler::Disassemble), mirroring
 * RenoDX's DisassembleShaderDXC (src/utils/shader_compiler_directx.hpp).
 *
 * The RenoDX HLSL decompiler expects DXC-format disassembly (with
 * "; Input signature:" tables). dxc.exe -dumpbin only accepts DXIL containers,
 * so this host goes through the same API RenoDX itself uses.
 *
 * Build: x86_64-w64-mingw32-g++ -std=c++20 -O2 -o dxc-disasm.exe dxc-disasm.cpp -I<dxc>/inc
 * Run:   wine --bottle <bottle> dxc-disasm.exe <in.cso> [out.asm]
 *        (dxcompiler.dll/dxil.dll must sit next to the exe or in PATH)
 */
#include <windows.h>
#include <dxcapi.h>

#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

using DxcCreateInstanceProc = HRESULT(WINAPI*)(REFCLSID, REFIID, LPVOID*);

// MinGW ignores __declspec(uuid(...)), so the __uuidof<> GUIDs used below must be
// provided explicitly. Values are copied from the DXC release's dxcapi.h
// (CROSS_PLATFORM_UUIDOF / CLSID_ definitions).
#ifdef __MINGW32__
// NOLINTBEGIN(readability-identifier-naming)
static const GUID uuid_IDxcLibrary = {
    0xe5204dc7, 0xd18c, 0x4c3c, {0xbd, 0xfb, 0x85, 0x16, 0x73, 0x98, 0x0f, 0xe7}};
static const GUID uuid_IDxcCompiler = {
    0x8c210bf3, 0x011f, 0x4422, {0x8d, 0x70, 0x6f, 0x9a, 0xcb, 0x8d, 0xb6, 0x17}};
static const GUID uuid_IDxcBlob = {
    0x8ba5fb08, 0x5195, 0x40e2, {0xac, 0x58, 0x0d, 0x98, 0x9c, 0x3a, 0x01, 0x02}};
static const GUID clsid_DxcLibrary = {
    0x6245d6af, 0x66e0, 0x48fd, {0x80, 0xb4, 0x4d, 0x27, 0x17, 0x96, 0x74, 0x8c}};
static const GUID clsid_DxcCompiler = {
    0x73e22d93, 0xe6ce, 0x47f3, {0xb5, 0xbf, 0xf0, 0x66, 0x4f, 0x39, 0xc1, 0xb0}};
template <typename T>
const GUID& MinGwUuidOf();
template <>
const GUID& MinGwUuidOf<IDxcLibrary>() { return uuid_IDxcLibrary; }
template <>
const GUID& MinGwUuidOf<IDxcCompiler>() { return uuid_IDxcCompiler; }
template <>
const GUID& MinGwUuidOf<IDxcBlob>() { return uuid_IDxcBlob; }
#define RENODX_UUIDOF(T) (MinGwUuidOf<T>())
#define RENODX_CLSID_LIBRARY clsid_DxcLibrary
#define RENODX_CLSID_COMPILER clsid_DxcCompiler
// NOLINTEND(readability-identifier-naming)
#else
#define RENODX_UUIDOF(T) __uuidof(T)
#define RENODX_CLSID_LIBRARY RENODX_CLSID_LIBRARY
#define RENODX_CLSID_COMPILER RENODX_CLSID_COMPILER
#endif

static std::vector<unsigned char> ReadFile(const char* path) {
  FILE* fp = fopen(path, "rb");
  if (fp == nullptr) { fprintf(stderr, "Cannot open %s\n", path); exit(1); }
  fseek(fp, 0, SEEK_END);
  long length = ftell(fp);
  fseek(fp, 0, SEEK_SET);
  if (length <= 0) { fclose(fp); fprintf(stderr, "Empty file %s\n", path); exit(1); }
  std::vector<unsigned char> data(static_cast<size_t>(length));
  if (fread(data.data(), 1, data.size(), fp) != data.size()) {
    fclose(fp); fprintf(stderr, "Read failed %s\n", path); exit(1);
  }
  fclose(fp);
  return data;
}

int main(int argc, char** argv) {
  if (argc < 2) { fprintf(stderr, "usage: %s input.cso [output.asm]\n", argv[0]); return 2; }

  auto code = ReadFile(argv[1]);

  HMODULE dll = LoadLibraryA("dxcompiler.dll");
  if (dll == nullptr) { fprintf(stderr, "Could not load dxcompiler.dll\n"); return 1; }
  auto create_instance = reinterpret_cast<DxcCreateInstanceProc>(
      GetProcAddress(dll, "DxcCreateInstance"));
  if (create_instance == nullptr) { fprintf(stderr, "No DxcCreateInstance export.\n"); return 1; }

  IDxcLibrary* library = nullptr;
  if (FAILED(create_instance(RENODX_CLSID_LIBRARY, RENODX_UUIDOF(IDxcLibrary), reinterpret_cast<void**>(&library))) || library == nullptr) {
    fprintf(stderr, "Could not create IDxcLibrary.\n"); return 1;
  }

  IDxcBlobEncoding* source = nullptr;
  HRESULT hr = library->CreateBlobWithEncodingFromPinned(
      code.data(), static_cast<UINT32>(code.size()), CP_ACP, &source);
  if (FAILED(hr) || source == nullptr) {
    fprintf(stderr, "Could not create blob (hr=0x%08lX).\n", static_cast<unsigned long>(hr));
    return 1;
  }

  IDxcCompiler* compiler = nullptr;
  if (FAILED(create_instance(RENODX_CLSID_COMPILER, RENODX_UUIDOF(IDxcCompiler), reinterpret_cast<void**>(&compiler))) || compiler == nullptr) {
    fprintf(stderr, "Could not create IDxcCompiler.\n"); return 1;
  }

  IDxcBlobEncoding* disassembly = nullptr;
  hr = compiler->Disassemble(source, &disassembly);
  if (FAILED(hr) || disassembly == nullptr) {
    fprintf(stderr, "Disassemble failed (hr=0x%08lX).\n", static_cast<unsigned long>(hr));
    return 1;
  }

  IDxcBlob* blob = nullptr;
  if (FAILED(disassembly->QueryInterface(RENODX_UUIDOF(IDxcBlob), reinterpret_cast<void**>(&blob))) || blob == nullptr) {
    fprintf(stderr, "Could not query IDxcBlob.\n"); return 1;
  }

  const char* text = static_cast<const char*>(blob->GetBufferPointer());
  const size_t size = blob->GetBufferSize();
  if (argc >= 3) {
    FILE* out = fopen(argv[2], "wb");
    if (out == nullptr) fprintf(stderr, "Cannot write %s\n", argv[2]);
    else { fwrite(text, 1, size, out); fclose(out); }
  }
  fwrite(text, 1, size, stdout);

  blob->Release();
  disassembly->Release();
  compiler->Release();
  source->Release();
  library->Release();
  return 0;
}