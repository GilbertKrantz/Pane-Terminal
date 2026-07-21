import Foundation

/// Length-prefixed protocol spoken over the private Unix-domain socket owned
/// by the user's existing interactive zsh.
enum ZshCompletionProtocol {
    static let version = 1
    static let headerByteCount = 8
    static let maximumRequestBodyBytes = 128 * 1_024
    static let maximumResponseBodyBytes = 64 * 1_024

    enum ResponseStatus: String, Sendable {
        case ok
        case invalidRequest = "invalid-request"
        case unavailable
        case timedOut = "timed-out"
        case failed
    }

    struct Candidate: Equatable, Sendable {
        let replacementText: String
        let detail: String?
        let isDirectory: Bool
    }

    struct Response: Equatable, Sendable {
        let requestID: String
        let status: ResponseStatus
        let candidates: [Candidate]
    }

    /// Request bytes are:
    ///
    ///     8 lowercase ASCII hex body-length bytes
    ///     UTF-8 `1;id;deadline-epoch-ms;zsh-character-cursor;base64(buffer)`
    ///
    /// `cursorCharacterOffset` is measured like zsh's CURSOR (characters), not
    /// as an NSString/UTF-16 offset. The deadline lets the warm shell discard
    /// a request whose client timed out while zsh was not idle in ZLE.
    static func requestBytes(
        requestID: String,
        buffer: String,
        cursorCharacterOffset: Int,
        deadline: Date
    ) -> Data? {
        guard isValidRequestID(requestID), cursorCharacterOffset >= 0 else {
            return nil
        }

        let deadlineMilliseconds = Int64(deadline.timeIntervalSince1970 * 1_000)
        let encodedBuffer = Data(buffer.utf8).base64EncodedString()
        let body = "\(version);\(requestID);\(deadlineMilliseconds);\(cursorCharacterOffset);\(encodedBuffer)"
        return framedBody(Data(body.utf8), maximum: maximumRequestBodyBytes)
    }

    /// Response bytes use the same 8-byte hex length prefix. After removing
    /// that prefix and reading exactly the advertised byte count, pass the
    /// response body here. Its UTF-8 form is:
    ///
    ///     `1;id;status;base64(candidate-stream)`
    static func parseResponseBody(_ body: Data) -> Response? {
        guard body.count <= maximumResponseBodyBytes else { return nil }
        let fields = body.split(
            separator: UInt8(ascii: ";"),
            maxSplits: 3,
            omittingEmptySubsequences: false
        )
        guard fields.count == 4,
              fields[0].elementsEqual(Data(String(version).utf8)),
              let requestID = String(data: fields[1], encoding: .utf8),
              isValidRequestID(requestID),
              let statusText = String(data: fields[2], encoding: .utf8),
              let status = ResponseStatus(rawValue: statusText) else {
            return nil
        }

        if status != .ok {
            guard fields[3].isEmpty else { return nil }
            return Response(requestID: requestID, status: status, candidates: [])
        }

        guard let decoded = Data(base64Encoded: Data(fields[3])),
              let candidates = parseCandidateStream(decoded) else {
            return nil
        }
        return Response(requestID: requestID, status: status, candidates: candidates)
    }

    /// Parses and bounds the 8-byte ASCII hex header used in both directions.
    static func bodyLength(fromHeader header: Data, maximum: Int) -> Int? {
        guard header.count == headerByteCount,
              let text = String(data: header, encoding: .ascii),
              text.utf8.allSatisfy({ byte in
                  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                      || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
              }),
              let length = Int(text, radix: 16),
              length > 0,
              length <= maximum else {
            return nil
        }
        return length
    }

    private static func framedBody(_ body: Data, maximum: Int) -> Data? {
        guard !body.isEmpty, body.count <= maximum else { return nil }
        var framed = Data(String(format: "%08x", body.count).utf8)
        framed.append(body)
        return framed
    }

    private static func isValidRequestID(_ requestID: String) -> Bool {
        guard !requestID.isEmpty, requestID.utf8.count <= 64 else { return false }
        return requestID.utf8.allSatisfy { byte in
            byte == UInt8(ascii: "-")
                || byte == UInt8(ascii: "_")
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
        }
    }

    private static func parseCandidateStream(_ data: Data) -> [Candidate]? {
        let signature = Data("PZC1".utf8)
        guard data.starts(with: signature) else { return nil }
        var index = signature.count
        guard let count = parseLength(in: data, index: &index), count <= 100 else {
            return nil
        }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(count)
        for _ in 0..<count {
            guard let replacementData = parseBlob(in: data, index: &index),
                  let detailData = parseBlob(in: data, index: &index),
                  index < data.count else {
                return nil
            }
            let flag = data[index]
            index += 1
            guard (flag == UInt8(ascii: "0") || flag == UInt8(ascii: "1")),
                  let replacement = String(data: replacementData, encoding: .utf8),
                  !replacement.isEmpty,
                  let detailText = String(data: detailData, encoding: .utf8) else {
                return nil
            }
            candidates.append(
                Candidate(
                    replacementText: replacement,
                    detail: detailText.isEmpty ? nil : detailText,
                    isDirectory: flag == UInt8(ascii: "1")
                )
            )
        }
        guard index == data.count else { return nil }
        return candidates
    }

    private static func parseBlob(in data: Data, index: inout Int) -> Data? {
        guard let length = parseLength(in: data, index: &index),
              length <= maximumResponseBodyBytes,
              index <= data.count - length else {
            return nil
        }
        defer { index += length }
        return data.subdata(in: index..<(index + length))
    }

    private static func parseLength(in data: Data, index: inout Int) -> Int? {
        guard index < data.count else { return nil }
        var value = 0
        var digitCount = 0
        while index < data.count, data[index] != UInt8(ascii: ":") {
            let byte = data[index]
            guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte),
                  digitCount < 8 else {
                return nil
            }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
            digitCount += 1
            index += 1
        }
        guard digitCount > 0, index < data.count else { return nil }
        index += 1
        return value
    }
}

enum ShellIntegration {
    /// A small lifecycle-only fallback used if Pane cannot create its private
    /// completion endpoint or integration file.
    static let installationCommand = encodedCommand(for: lifecycleInstallationScript)

    /// The app creates the containing directory with mode 0700 and chooses a
    /// unique, nonexistent socket path. The integration source is written into
    /// that private directory so the PTY only receives a short `source`
    /// command; sending the full encoded script can overflow a terminal's
    /// canonical input queue before zsh has drained it.
    static func installationCommand(completionSocketPath: String) -> String {
        let directoryURL = URL(fileURLWithPath: completionSocketPath)
            .deletingLastPathComponent()
        let scriptURL = directoryURL.appendingPathComponent("integration.zsh")
        let quotedSocketPath = shellSingleQuoted(completionSocketPath)
        let source = "typeset -g __pane_completion_socket_path=\(quotedSocketPath)\n\(installationScript)\n"

        do {
            try Data(source.utf8).write(to: scriptURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: scriptURL.path
            )
            return "builtin source \(shellSingleQuoted(scriptURL.path))"
        } catch {
            return installationCommand
        }
    }

    private static func encodedCommand(for script: String) -> String {
        let payload = Data(script.utf8).base64EncodedString()
        return "builtin eval \"$(printf %s '\(payload)' | /usr/bin/base64 -D)\""
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static let lifecycleInstallationScript = #"""
function __pane_preexec() {
  local __pane_command_b64=$(printf %s "$1" | /usr/bin/base64 | /usr/bin/tr -d '\n')
  printf '\e]777;Pane;START;%s\a' "$__pane_command_b64"
}

function __pane_precmd() {
  local __pane_status=$?
  printf '\e]777;Pane;END;%d;%s\a' "$__pane_status" "$PWD"
}

autoload -Uz add-zsh-hook
add-zsh-hook -d preexec __pane_preexec 2>/dev/null
add-zsh-hook -d precmd __pane_precmd 2>/dev/null
add-zsh-hook preexec __pane_preexec
add-zsh-hook precmd __pane_precmd
"""#

    private static let installationScript = #"""
function __pane_preexec() {
  # Unix listener descriptors created by zsocket are inherited by exec. Close
  # the idle-only listener before the user's process is forked so git, brew,
  # language servers, and other descendants never retain Pane's endpoint.
  __pane_completion_close_socket
  local __pane_command_b64=$(printf %s "$1" | /usr/bin/base64 | /usr/bin/tr -d '\n')
  printf '\e]777;Pane;START;%s\a' "$__pane_command_b64"
}

function __pane_precmd() {
  local __pane_status=$?
  # Recreate the endpoint only once the shell is idle at a prompt again.
  __pane_completion_install_socket
  printf '\e]777;Pane;END;%d;%s\a' "$__pane_status" "$PWD"
}

autoload -Uz add-zsh-hook
add-zsh-hook -d preexec __pane_preexec 2>/dev/null
add-zsh-hook -d precmd __pane_precmd 2>/dev/null
add-zsh-hook preexec __pane_preexec
add-zsh-hook precmd __pane_precmd

function __pane_completion_child_finish() {
  local -i __pane_count=$#__pane_completion_replacements
  print -r -- "__PANE_ZPTY_BEGIN_${__pane_completion_nonce}__"
  {
    local LC_ALL=C
    printf 'PZC1%d:' "$__pane_count"
    local -i __pane_index
    for (( __pane_index = 1; __pane_index <= __pane_count; ++__pane_index )); do
      local __pane_replacement=$__pane_completion_replacements[$__pane_index]
      local __pane_detail=$__pane_completion_details[$__pane_index]
      printf '%d:%s%d:%s%s' \
        $#__pane_replacement "$__pane_replacement" \
        $#__pane_detail "$__pane_detail" \
        "$__pane_completion_directory_flags[$__pane_index]"
    done
  } | /usr/bin/base64
  print -r -- "__PANE_ZPTY_END_${__pane_completion_nonce}__"
  exit 0
}

function __pane_completion_child() {
  setopt localoptions extendedglob noaliases
  zmodload zsh/parameter 2>/dev/null || return 1
  zmodload zsh/zutil 2>/dev/null || return 1

  # zsocket descriptors are inherited across fork. The capture child never
  # serves clients, and closing its copies prevents descriptor/socket leaks.
  { exec {__pane_completion_listener_fd}>&- } 2>/dev/null
  { exec {__pane_completion_active_client_fd}>&- } 2>/dev/null

  if (( ! $+functions[_main_complete] )); then
    autoload -Uz compinit
    compinit -C 2>/dev/null || return 1
  fi
  autoload +X _main_complete 2>/dev/null || return 1

  typeset -ga __pane_completion_replacements=()
  typeset -ga __pane_completion_details=()
  typeset -ga __pane_completion_directory_flags=()
  typeset -gi __pane_completion_payload_bytes=0

  function compadd() {
    if [[ ${@[1,(i)(-|--)]} == *-(O|A|D)\ * ]]; then
      builtin compadd "$@"
      return $?
    fi

    local -a __pane_hits __pane_descriptions __pane_description_argument
    if (( $@[(I)-d] )); then
      __pane_description_argument=${@[$[${@[(i)-d]}+1]]}
      if [[ $__pane_description_argument == \(* ]]; then
        eval "__pane_descriptions=$__pane_description_argument"
      else
        __pane_descriptions=( "${(@P)__pane_description_argument}" )
      fi
    fi

    builtin compadd -A __pane_hits -D __pane_descriptions "$@"
    local __pane_status=$?
    setopt localoptions extendedglob norcexpandparam

    local -A __pane_added_prefix __pane_hidden_prefix
    local -A __pane_added_suffix __pane_hidden_suffix
    zparseopts -E P:=__pane_added_prefix p:=__pane_hidden_prefix \
      S:=__pane_added_suffix s:=__pane_hidden_suffix

    local -i __pane_add_directory_suffix=0
    if [[ -z $__pane_hidden_suffix && "${${@//-default-/}% -# *}" == *-[[:alnum:]]#f* ]]; then
      __pane_add_directory_suffix=1
    fi

    local -i __pane_index
    for (( __pane_index = 1; __pane_index <= $#__pane_hits; ++__pane_index )); do
      (( $#__pane_completion_replacements >= 100 )) && break
      local __pane_hit=$__pane_hits[$__pane_index]
      local __pane_directory_suffix= __pane_is_directory=0
      if (( __pane_add_directory_suffix )) && [[ -d "$IPREFIX$__pane_hit" ]]; then
        __pane_directory_suffix=/
        __pane_is_directory=1
      fi

      local __pane_detail=
      if (( $#__pane_descriptions >= __pane_index )); then
        __pane_detail="${${__pane_descriptions[$__pane_index]}##$__pane_hit #}"
        __pane_detail=${__pane_detail#-- }
      fi
      local __pane_replacement=$IPREFIX$__pane_added_prefix$__pane_hidden_prefix$__pane_hit$__pane_directory_suffix$__pane_hidden_suffix$__pane_added_suffix

      local LC_ALL=C
      local -i __pane_record_bytes=$#__pane_replacement+$#__pane_detail+32
      (( __pane_record_bytes > 24000 )) && continue
      (( __pane_completion_payload_bytes + __pane_record_bytes > 32000 )) && break
      __pane_completion_payload_bytes+=$__pane_record_bytes
      __pane_completion_replacements+=("$__pane_replacement")
      __pane_completion_details+=("$__pane_detail")
      __pane_completion_directory_flags+=("$__pane_is_directory")
    done
    return $__pane_status
  }

  local -a +h compprefuncs comppostfuncs
  compprefuncs=()
  comppostfuncs=(__pane_completion_child_finish)

  zle -C __pane_completion_completer .complete-word _main_complete
  function __pane_completion_child_widget() {
    BUFFER=$__pane_completion_buffer
    CURSOR=$__pane_completion_cursor
    zle __pane_completion_completer
  }
  zle -N __pane_completion_child_widget
  COLUMNS=240 LINES=40
  PROMPT= RPROMPT= PS2= RPS2=
  zle __pane_completion_child_widget
  # Most completion paths invoke comppostfuncs above, which exits the child.
  # Preserve a valid empty result if a custom completion bypasses that hook.
  __pane_completion_child_finish
}

function __pane_completion_read_exact() {
  local -i __pane_fd=$1 __pane_wanted=$2
  local -F __pane_deadline=$3
  local __pane_chunk
  REPLY=
  local LC_ALL=C
  while (( $#REPLY < __pane_wanted && EPOCHREALTIME < __pane_deadline )); do
    local -i __pane_remaining=$(( __pane_wanted - $#REPLY ))
    if sysread -i $__pane_fd -s $__pane_remaining -t 0.02 __pane_chunk 2>/dev/null; then
      REPLY+=$__pane_chunk
    elif (( $? == 5 )); then
      return 1
    fi
  done
  (( $#REPLY == __pane_wanted ))
}

function __pane_completion_write_all() {
  local -i __pane_fd=$1
  local __pane_pending=$2
  local -i __pane_written
  local LC_ALL=C
  while (( $#__pane_pending > 0 )); do
    syswrite -o $__pane_fd -c __pane_written "$__pane_pending" 2>/dev/null || return 1
    (( __pane_written > 0 )) || return 1
    __pane_pending=${__pane_pending[$(( __pane_written + 1 )),-1]}
  done
}

function __pane_completion_send_response() {
  local -i __pane_fd=$1
  local __pane_id=$2 __pane_status=$3 __pane_payload=$4
  local __pane_body="1;${__pane_id};${__pane_status};${__pane_payload}"
  local LC_ALL=C
  (( $#__pane_body <= 65536 )) || {
    __pane_body="1;${__pane_id};failed;"
  }
  local __pane_header
  printf -v __pane_header '%08x' $#__pane_body
  __pane_completion_write_all $__pane_fd "$__pane_header$__pane_body"
}

function __pane_completion_socket_handler() {
  emulate -L zsh
  setopt extendedglob
  local -i __pane_listen_fd=$1
  if [[ -n $2 ]]; then
    zle -F $__pane_listen_fd 2>/dev/null
    { exec {__pane_listen_fd}>&- } 2>/dev/null
    if (( ${+__pane_completion_listener_fd} )) \
        && (( __pane_completion_listener_fd == __pane_listen_fd )); then
      unset __pane_completion_listener_fd
    fi
    [[ -n $__pane_completion_socket_path ]] \
      && /bin/rm -f -- "$__pane_completion_socket_path" 2>/dev/null
    return 0
  fi
  zsocket -a -t $__pane_listen_fd 2>/dev/null || return 0
  local -i __pane_client_fd=$REPLY
  typeset -gi __pane_completion_active_client_fd=$__pane_client_fd
  local __pane_header __pane_body
  local __pane_id=unknown __pane_status=invalid-request __pane_payload=
  local -F __pane_read_deadline=$(( EPOCHREALTIME + 0.10 ))

  if __pane_completion_read_exact $__pane_client_fd 8 $__pane_read_deadline; then
    __pane_header=$REPLY
    if [[ $__pane_header == [0-9a-f]## ]]; then
      local -i __pane_length=$(( 16#$__pane_header ))
      if (( __pane_length > 0 && __pane_length <= 131072 )) \
          && __pane_completion_read_exact $__pane_client_fd $__pane_length $__pane_read_deadline; then
        __pane_body=$REPLY
        local -a __pane_fields=( "${(@s:;:)__pane_body}" )
        if (( $#__pane_fields == 5 )) \
            && [[ $__pane_fields[1] == 1 ]] \
            && [[ $__pane_fields[2] == [A-Za-z0-9_-]## ]] \
            && (( ${#__pane_fields[2]} <= 64 )) \
            && [[ $__pane_fields[3] == <-> ]] \
            && [[ $__pane_fields[4] == <-> ]]; then
          __pane_id=$__pane_fields[2]
          local -i __pane_now_ms=$(( EPOCHREALTIME * 1000 ))
          if (( __pane_fields[3] < __pane_now_ms )); then
            __pane_status=timed-out
          else
            local __pane_decoded_buffer
            __pane_decoded_buffer=$(printf %s "$__pane_fields[5]" | /usr/bin/base64 -D 2>/dev/null; printf .)
            local __pane_decode_status=$pipestatus[1]
            __pane_decoded_buffer=${__pane_decoded_buffer%.}
            if (( __pane_decode_status == 0 )); then
              typeset -g __pane_completion_buffer=$__pane_decoded_buffer
              typeset -gi __pane_completion_cursor=$__pane_fields[4]
              typeset -g __pane_completion_nonce=${$}_${RANDOM}_${RANDOM}

              local __pane_pty="__pane_completion_${__pane_completion_nonce}"
              local __pane_chunk __pane_output=
              local -F __pane_capture_deadline=$(( EPOCHREALTIME + 0.50 ))
              zpty -b "$__pane_pty" __pane_completion_child
              local -i __pane_zpty_status=$? __pane_zpty_fd=$REPLY
              if (( __pane_zpty_status == 0 )); then
                while (( EPOCHREALTIME < __pane_capture_deadline )); do
                  while zpty -rt "$__pane_pty" __pane_chunk; do
                    __pane_output+=$__pane_chunk
                    (( $#__pane_output > 60000 )) && break 2
                  done
                  if [[ $__pane_output == *"__PANE_ZPTY_END_${__pane_completion_nonce}__"* ]]; then
                    break
                  fi
                  zpty -t "$__pane_pty" || break
                  zselect -r $__pane_zpty_fd -t 2 2>/dev/null
                done

                local __pane_begin="__PANE_ZPTY_BEGIN_${__pane_completion_nonce}__"
                local __pane_end="__PANE_ZPTY_END_${__pane_completion_nonce}__"
                if [[ $__pane_output == *$__pane_begin* && $__pane_output == *$__pane_end* ]]; then
                  __pane_payload=${__pane_output#*$__pane_begin}
                  __pane_payload=${__pane_payload%%$__pane_end*}
                  __pane_payload=${__pane_payload//$'\r'/}
                  __pane_payload=${__pane_payload//$'\n'/}
                  __pane_status=ok
                elif (( EPOCHREALTIME >= __pane_capture_deadline )); then
                  __pane_status=timed-out
                else
                  __pane_status=failed
                fi
              else
                __pane_status=failed
              fi
              zpty -d "$__pane_pty" 2>/dev/null
              unset __pane_completion_buffer __pane_completion_cursor __pane_completion_nonce
            fi
          fi
        fi
      fi
    fi
  fi

  __pane_completion_send_response $__pane_client_fd "$__pane_id" "$__pane_status" "$__pane_payload"
  { exec {__pane_client_fd}>&- } 2>/dev/null
  unset __pane_completion_active_client_fd
  return 0
}

function __pane_completion_install_socket() {
  [[ -n $__pane_completion_socket_path ]] || return 0
  zmodload zsh/net/socket 2>/dev/null || return 1
  zmodload zsh/system 2>/dev/null || return 1
  zmodload zsh/zpty 2>/dev/null || return 1
  zmodload zsh/zselect 2>/dev/null || return 1
  zmodload zsh/datetime 2>/dev/null || return 1

  __pane_completion_close_socket
  zsocket -l "$__pane_completion_socket_path" 2>/dev/null || return 1
  typeset -gi __pane_completion_listener_fd=$REPLY
  zle -F $__pane_completion_listener_fd __pane_completion_socket_handler
}

function __pane_completion_close_socket() {
  if (( ${+__pane_completion_listener_fd} )); then
    zle -F $__pane_completion_listener_fd 2>/dev/null
    # Keep the stderr redirection outside `exec`: an `exec` with no command
    # applies its own redirections permanently to the user's warm shell.
    { exec {__pane_completion_listener_fd}>&- } 2>/dev/null
    unset __pane_completion_listener_fd
  fi
  # The path lives in an app-created mode-0700 directory and is unique to this
  # shell generation. AF_UNIX requires unlinking it before the next bind.
  [[ -n $__pane_completion_socket_path ]] \
    && /bin/rm -f -- "$__pane_completion_socket_path" 2>/dev/null
}

__pane_completion_install_socket
"""#
}
