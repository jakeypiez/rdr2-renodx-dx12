/*
 * Standalone macOS driver for RenoDX's DXBC -> HLSL decompiler.
 *
 * RenoDX's own `decomp` tool (src/decompiler/cli.cpp) calls DisassembleShader(),
 * which needs D3DCompiler/DXC. Those are Windows-only. This driver keeps the
 * decompiler half (src/utils/shader_decompiler_dxc.hpp, pure standard C++) and
 * takes already-produced DXBC disassembly text, which we generate with
 * tools/dxbc-disasm.exe under CrossOver.
 *
 * Build: c++ -std=c++20 -O2 -o tools/decomp-mac tools/decomp-mac.cpp
 * Run:   tools/decomp-mac input.asm output.hlsl [--flatten] [--use-do-while]
 */
#include <cstdlib>
#include <exception>
#include <fstream>
#include <iostream>
#include <iterator>
#include <ranges>
#include <sstream>
#include <string>
#include <vector>

#include "../renodx-src/src/utils/shader_decompiler_dxc.hpp"

static std::string ReadTextFile(const std::string& path) {
  std::ifstream stream(path, std::ios::binary);
  if (!stream) throw std::runtime_error("Cannot open " + path);
  std::ostringstream buffer;
  buffer << stream.rdbuf();
  if (!stream.good() && !stream.eof()) throw std::runtime_error("Read failed " + path);
  return buffer.str();
}

int main(int argc, char** argv) {
  std::vector<std::string> arguments(argv + 1, argv + argc);
  std::vector<std::string> paths;
  for (auto& argument : arguments) {
    if (argument.empty() || argument[0] != '-') paths.push_back(argument);
  }
  if (paths.size() < 2) {
    std::cerr << "USAGE: decomp-mac {disassembly} {hlsl} [--flatten] [-f] [--use-do-while]\n";
    return EXIT_FAILURE;
  }

  const bool flatten = std::ranges::any_of(arguments, [](const std::string& a) {
    return a == "--flatten" || a == "-f";
  });
  const bool use_do_while = std::ranges::any_of(arguments, [](const std::string& a) {
    return a == "--use-do-while";
  });

  std::string disassembly;
  try {
    disassembly = ReadTextFile(paths[0]);
  } catch (const std::exception& ex) {
    std::cerr << ex.what() << '\n';
    return EXIT_FAILURE;
  }
  if (disassembly.empty()) {
    std::cerr << "Empty disassembly input.\n";
    return EXIT_FAILURE;
  }

  try {
    auto decompiler = renodx::utils::shader::decompiler::dxc::Decompiler();
    std::string decompilation = decompiler.Decompile(disassembly, {
                                                                        .flatten = flatten,
                                                                        .use_do_while = use_do_while,
                                                                    });
    if (decompilation.empty()) {
      std::cerr << "Decompilation produced no output.\n";
      return EXIT_FAILURE;
    }
    std::ofstream out(paths[1], std::ios::binary);
    if (!out) {
      std::cerr << "Cannot write " << paths[1] << '\n';
      return EXIT_FAILURE;
    }
    out << decompilation;
    out.close();
    std::cout << "OK -> " << paths[1] << " (" << decompilation.size() << " bytes)\n";
  } catch (const std::exception& ex) {
    std::cerr << "Decompilation failed: " << ex.what() << '\n';
    return EXIT_FAILURE;
  }
  return EXIT_SUCCESS;
}