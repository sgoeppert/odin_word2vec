package main

import "core:fmt"
import "core:strings"
import "core:os"
import "core:mem"
import "core:io"
import "core:bufio"
import "core:unicode/utf8"
import "core:slice"
import "core:strconv"


MAX_STRING :: 100
VOCAB_HASH_SIZE :: 1_000
MIN_COUNT :: 2
STOP_TOKEN := [4]rune{'<', '/', 's', '>'}

Word :: []rune

// word_make :: proc(slic: []rune) -> Word {
//     return Word(slice.clone(slic))
// }
// word_from_string :: proc(str: string) -> Word {
//     return Word(utf8.string_to_runes(str))
// }

word_hash :: proc(word: Word) -> u32 {
    hash : u32
    for r in word {
        hash = hash * 257 + u32(r)
    }
    hash = hash % VOCAB_HASH_SIZE
    return hash
}

VocabWord :: struct {
    word: Word,
    count: int,
}

vocab_word_make :: proc(word: Word) -> VocabWord {
    return VocabWord{
        word = word,
        count = 0,
    }
}
vocab_word_delete :: proc(word: ^VocabWord) {
    delete(word.word)
    word.word = nil
}

Vocab :: struct {
    words: [dynamic]VocabWord,
    hashes: []int,
    size: int,
    train_words: int,
}

vocab_make :: proc() -> Vocab {
    words := make([dynamic]VocabWord, 0, 1000)
    hashes := make([]int, VOCAB_HASH_SIZE)

    for &hash in hashes {
        hash = -1
    }

    // reserve(&words, 1000)

    return Vocab{
        words = words,
        hashes = hashes,
        size = 0,
        train_words = 0,
    }
}

vocab_delete :: proc(vocab: Vocab) {
    for &word in vocab.words {
        vocab_word_delete(&word)
    }
    delete(vocab.words)
    delete(vocab.hashes)
}

vocab_reduce :: proc(vocab: ^Vocab) {
    @(static) min_reduce := 0
    
    // fmt.println("Reducing Vocabulary")
    // fmt.printfln("Current size: %v, allowed size: %v", vocab.size, VOCAB_HASH_SIZE * 0.7)
    // fmt.println("min_reduce: ", min_reduce)
    // fmt.printfln("len(vocab.words): %v cap(vocab.words): %v", len(vocab.words), cap(vocab.words))

    a, b : int
    for a = 0; a < vocab.size; a += 1 {
        if vocab.words[a].count > min_reduce {
            vocab.words[b] = vocab.words[a]
            b += 1
        } else {
            vocab_word_delete(&vocab.words[a])
        }
    }
    vocab.size = b
    resize(&vocab.words, b)
    vocab_recalculate_hashes(vocab)

    min_reduce += 1
}

/*
Sort the vocabulary by word count and remove infrequent words
*/
vocab_sort :: proc(vocab: ^Vocab) {
    slice.sort_by(vocab.words[1:], proc(a, b: VocabWord) -> bool {
        return a.count > b.count
    })
    vocab.train_words = 0

    for i := 0; i < VOCAB_HASH_SIZE; i += 1 {
        vocab.hashes[i] = -1
    }

    size := vocab.size
    for i := 0; i < size; i += 1 {
        if vocab.words[i].count < MIN_COUNT && i != 0 {
            vocab.size -= 1
            vocab_word_delete(&vocab.words[i])
        } else {
            hash := vocab_get_word_hash(vocab, vocab.words[i].word)
            vocab.hashes[hash] = i
            vocab.train_words += vocab.words[i].count
        }
    }
    resize(&vocab.words, vocab.size)
}

vocab_recalculate_hashes :: proc(vocab: ^Vocab) {
    for i := 0; i < VOCAB_HASH_SIZE; i += 1 {
        vocab.hashes[i] = -1
    }
    for i := 0; i < vocab.size; i += 1 {
        hash := vocab_get_word_hash(vocab, vocab.words[i].word)
        vocab.hashes[hash] = i
    }
}

vocab_get_word_hash :: proc(vocab: ^Vocab, word: Word) -> u32 {
    hash := word_hash(word)
    first_hash := hash
    for vocab.hashes[hash] != -1 {
        hash = (hash + 1) % VOCAB_HASH_SIZE

        if hash == first_hash {
            panic("Vocabulary full")
        }
    }
    return hash
}

vocab_add_word :: proc(vocab: ^Vocab, word: Word) -> int {
    word := slice.clone(word)
    vocab_word := vocab_word_make(word)
    index := vocab.size

    vocab.size += 1
    append(&vocab.words, vocab_word)


    hash := vocab_get_word_hash(vocab, word)
    vocab.hashes[hash] = index
    return index
}

vocab_search_word :: proc(vocab: ^Vocab, word: Word) -> (index: int, found: bool) {
    hash := word_hash(word)

    first_hash := hash
    for {
        if vocab.hashes[hash] == -1 {
            return -1, false
        }

        i := vocab.hashes[hash]
        if slice.equal(vocab.words[i].word, word) {
            return i, true
        }
        hash = (hash + 1) % VOCAB_HASH_SIZE
        if hash == first_hash {
            panic("Vocabulary full")
        }
    }
}

vocab_save :: proc(vocab: Vocab, file_path: string) {
    f, err := os.open(file_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
    if err != os.ERROR_NONE {
        fmt.eprintfln("Error opening file \"%s\"", file_path)
        return
    }
    for word in vocab.words {
        fmt.fprintf(f, "%s %d\n", word.word, word.count)
    }
    os.close(f)
}

vocab_load :: proc(file_path: string) -> Vocab {
    f, err := os.open(file_path, os.O_RDONLY)
    if err != os.ERROR_NONE {
        fmt.eprintfln("Error opening vocabulary file \"%s\"", file_path)
        os.exit(1)
    }

    reader : bufio.Reader
    buf : [1024]byte
    word_buf : [MAX_STRING]rune

    bufio.reader_init_with_buf(&reader, os.stream_from_handle(f), buf[:])
    defer bufio.reader_destroy(&reader)

    vocab := vocab_make()

    count_buf : [10]rune
    line := 0
    for {
        eof : bool
        word: []rune
        count: []rune

        word, eof = read_word(&reader, word_buf[:])
        if eof {
            break
        }
        if len(word) == 0 {
            fmt.eprintfln("Error reading word from vocabulary file \"%s\" line %i", file_path, line + 1)
            os.exit(1)
        } else if line > 0 && slice.equal(word, STOP_TOKEN[:]) {
            continue
        }

        count, eof = read_word(&reader, count_buf[:])
        if len(count) == 0 {
            fmt.eprintfln("Error reading count from vocabulary file \"%s\" line %i", file_path, line + 1)
            os.exit(1)
        }

        count_val : int
        for r in count {
            if r < '0' || r > '9' {
                fmt.eprintfln("Error parsing count as int \"%s\"", count)
                os.exit(1)
            }
            count_val = count_val * 10 + int(r - '0')
        }

        idx := vocab_add_word(&vocab, word)
        vocab.words[idx].count = count_val

        line += 1

        if eof {
            break
        }
    }
    vocab_sort(&vocab)

    return vocab
}

learn_vocab_from_file :: proc(file_path: string) -> Vocab {
    f, ok := os.open(file_path, os.O_RDONLY)
    if ok != os.ERROR_NONE {
        fmt.eprintfln("Error opening training file \"%s\"", file_path)
        os.exit(1)
    }
    defer os.close(f)

    reader : bufio.Reader
    buf : [1024]byte

    bufio.reader_init_with_buf(&reader, os.stream_from_handle(f), buf[:])
    defer bufio.reader_destroy(&reader)

    vocab := vocab_make()

    vocab_add_word(&vocab, STOP_TOKEN[:])

    word_buf : [MAX_STRING]rune
    for {


        word, eof := read_word(&reader, word_buf[:])
        
        if len(word) > 0 {
            vocab.train_words += 1

            if idx, found := vocab_search_word(&vocab, word); !found {
                idx = vocab_add_word(&vocab, word)
                vocab.words[idx].count = 1
            } else {
                vocab.words[idx].count += 1
            }
        }
        
        if vocab.size > VOCAB_HASH_SIZE * 0.7 {
            vocab_reduce(&vocab)
        }

        if eof {
            break
        }
    }

    vocab_sort(&vocab)

    fmt.printfln("Vocab size: %v", vocab.size)
    fmt.printfln("Train words: %v", vocab.train_words)

    return vocab
}

/*
Reads a new word from the reader

Inputs:
- reader: The reader to read from
- buff: A buffer to store the word in

Returns:
- the_word: A slice into the buff containing the word read from the reader (or </s> if newline)
- eof: Whether the end of the file was reached

*/
read_word :: proc(reader: ^bufio.Reader, buff: []rune) -> (the_word: []rune, eof: bool) {
    
    i := 0

    for {
        r, size, err := bufio.reader_read_rune(reader)
        if err != nil {
            return buff[:i], true
        }

        // Skip carriage return
        if r == '\r' {
            continue
        }
        
        // Whitespace marks end of word
        if r == ' ' || r == '\t' || r == '\n' {
            // If word is not empty, return it
            if i > 0 {
                if r == '\n' {
                    // Put back newlines so we pick it up as </s> next go round
                    bufio.reader_unread_rune(reader)
                }
                break
            }

            // If word is empty and we hit newline, return it as </s>
            if r == '\n' {
                return STOP_TOKEN[:], false
            } else {
                // Skip other whitespace
                continue
            }
        }

        // Add next rune to buffer
        buff[i] = r
        i += 1

        // Limit word length
        if i >= MAX_STRING - 1 {
            i -= 1
        }
    }
    
    return buff[:i], false
}


Arguments :: struct {
    save_vocab : bool,
    learn_vocab : bool,
    train_file : string,
    vocab_file : string,
}

arguments_make :: proc() -> Arguments {
    return Arguments{
        train_file = "data/witcher3.txt",
        vocab_file = "data/vocab.txt",
    }
}

main :: proc() {
    
    args := arguments_make()

    for i := 1; i < len(os.args); i += 1 {
        arg := os.args[i]
        if arg == "-s" || arg == "--save" {
            args.save_vocab = true
        } else if arg == "-l" || arg == "--learn" {
            args.learn_vocab = true
        }
    }
    if !args.learn_vocab && !os.exists(args.vocab_file) {
        fmt.eprintfln("Vocabulary file \"%s\" not found", args.vocab_file)
        os.exit(1)
    }

    fmt.println("Arguments: ", args)

    /// Setting up the tracking allocator
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    context.allocator = mem.tracking_allocator(&track)


    defer {
        if len(track.allocation_map) > 0 {
            fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
            for _, entry in track.allocation_map {
                fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
            }
        }
        if len(track.bad_free_array) > 0 {
            fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
            for entry in track.bad_free_array {
                fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
            }
        }
        mem.tracking_allocator_destroy(&track)
    }

    vocab : Vocab
    if args.learn_vocab {
        vocab = learn_vocab_from_file(args.train_file)
    } else {
        vocab = vocab_load(args.vocab_file)
    }

    fmt.println(vocab)

    if args.save_vocab {
        vocab_save(vocab, args.vocab_file)
    }

    defer vocab_delete(vocab)
    
}