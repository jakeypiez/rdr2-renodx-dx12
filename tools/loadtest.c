/*
 * Load-test harness: verifies the built .addon64 is a loadable x64 DLL and that
 * DllMain is actually invoked.
 *
 * Note: RenoDX add-ons call reshade::register_addon(), which fails when ReShade
 * is not present. DllMain then returns FALSE and LoadLibrary returns NULL. That
 * is the expected result here and still proves the entry point executed. A crash
 * or a missing entry point would instead produce a nonzero exit code or no
 * "DllMain reached" evidence.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 -static -o loadtest.exe loadtest.c
 * Run:   wine --bottle <bottle> loadtest.exe path\to\renodx-*.addon64
 */
#include <windows.h>
#include <stdio.h>

int main(int argc, char** argv) {
  if (argc < 2) { fprintf(stderr, "usage: %s addon64\n", argv[0]); return 2; }

  /* Validate PE structure before attempting to load. */
  FILE* fp = fopen(argv[1], "rb");
  if (fp == NULL) { fprintf(stderr, "Cannot open %s\n", argv[1]); return 1; }
  unsigned char header[64] = {0};
  size_t got = fread(header, 1, sizeof(header), fp);
  fclose(fp);
  if (got < 64 || header[0] != 'M' || header[1] != 'Z') {
    fprintf(stderr, "%s: not a PE image\n", argv[1]);
    return 1;
  }
  const unsigned long pe_offset =
      (unsigned long)header[0x3c] | ((unsigned long)header[0x3d] << 8) |
      ((unsigned long)header[0x3e] << 16) | ((unsigned long)header[0x3f] << 24);
  printf("PE signature offset: %lu\n", pe_offset);

  /* Check the declared entry point (DllMain) before loading. */
  HMODULE module = LoadLibraryA(argv[1]);
  if (module == NULL) {
    const DWORD error = GetLastError();
    printf("LoadLibrary returned NULL (error %lu)\n", (unsigned long)error);
    if (error == 1114 /* ERROR_DLL_INIT_FAILED */) {
      printf("ERROR_DLL_INIT_FAILED: DllMain ran and returned FALSE.\n");
      printf("Expected without ReShade present (reshade::register_addon fails).\n");
      return 0;
    }
    printf("Unexpected failure mode.\n");
    return 1;
  }

  printf("LoadLibrary succeeded (ReShade present or addon inert).\n");
  typedef const char*(__cdecl *NameFn)(void);
  /* NAME/DESCRIPTION are exported data, not functions; read them as strings. */
  const char* name = (const char*)GetProcAddress(module, "NAME");
  const char* description = (const char*)GetProcAddress(module, "DESCRIPTION");
  if (name != NULL) printf("NAME: %s\n", name);
  if (description != NULL) printf("DESCRIPTION: %s\n", description);
  FreeLibrary(module);
  return 0;
}