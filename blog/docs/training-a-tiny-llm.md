---
title: Training a tiny language model on a laptop
description: An attempt to understand what is going on in a very basic model.
date: 2026-09-17
type: Guide
tags: [MLX, Python, LLM]
featured: true
---


This post describes how to train a small GPT-style language model from scratch on an Apple silicon Mac, using children's stories and a set of technical documentation as the training data. TinyStories is a public corpus of short stories written in the vocabulary of a three-year-old. It is about two gigabytes of plain text, and a model with a few tens of millions of parameters learns to produce coherent stories from it.

It covers the tokenizer, the data pipeline, the model, the training loop and sampling. The project is at `github.com/binarycodes/tiny-llm`.

A language model itself does one thing. Given a sequence of tokens, it produces a probability for each token in the vocabulary being the next one. Training pushes those probabilities towards the token that actually followed in the text. Generation samples a token from them, appends it and repeats. Everything the project has to do follows from that exchange. It turns text into tokens, it predicts the next one, and it turns tokens back into text.

## The stack

The project is built on Python 3.13 and MLX, Apple's array framework for its own silicon. MLX runs on the GPU through unified memory, so there is no copying between host and device, and it provides the layers, the optimiser and the automatic differentiation. The project has four runtime dependencies:

```toml
dependencies = [
    "mlx",
    "numpy",
    "safetensors",
    "tokenizers",
]
```

`tokenizers` is the Hugging Face library that trains and runs the byte-pair encoder. `numpy` holds the tokenized dataset, and `safetensors` is the checkpoint format.

The code splits into one module per stage, plus a configuration module and the model:

```
tiny_llm:
    config.py            -   every path and hyperparameter
    train_tokenizer.py   -   data/raw/**/*.txt -> data/tokenizer.json
    tokenize_dataset.py  -   data/raw/<source>/ -> data/tokenized/<source>.{train,valid}.bin
    model.py             -   the transformer
    train.py             -   the training loop -> checkpoints/best.safetensors
    generate.py          -   sampling from a checkpoint
```

Each stage reads the files the previous one wrote, so any of them can be rerun on its own. There is no command-line parsing apart from the prompt to `generate`. Everything else is a constant in `config.py`.

## The tokenizer

The tokenizer is a byte-level BPE with a vocabulary of 16,384 tokens, trained on every text file under `data/raw`:

```python
tokenizer = Tokenizer(BPE(unk_token="<unk>"))
tokenizer.pre_tokenizer = ByteLevel(add_prefix_space=False)
tokenizer.decoder = ByteLevelDecoder()

trainer = BpeTrainer(
    vocab_size=VOCAB_SIZE,
    min_frequency=2,
    special_tokens=["<pad>", "<unk>", "<bos>", "<eos>"],
)
tokenizer.train(files=[str(path) for path in files], trainer=trainer)
tokenizer.save(str(TOKENIZER_FILE))
```

Byte-level means the base alphabet is the 256 byte values, so any input can be encoded and the `<unk>` token is never actually produced. The vocabulary size is chosen to fit a 16-bit unsigned integer with room to spare. Token ids are stored as `uint16`, which halves the size of the tokenized dataset compared with `int32`, and the tokenizing step refuses to run if the vocabulary has outgrown the type.

Of the four special tokens only `<eos>` is used. It is appended to every document so the model learns where a story ends, and generation stops when it is sampled.

## The dataset

Each subdirectory under `data/raw` is a source. There are two, `tinystories` and `technical`, the second being a few hundred pages of [Vaadin documentation](https://vaadin.com/docs) exported as plain text. The tokenizing step writes a training file and a validation file per source.

TinyStories comes as one two-gigabyte file with the stories separated by `<|endoftext|>`. The file is read in four-megabyte chunks and split on the separator, carrying the tail of each chunk over to the next:

```python
def iter_documents(path: Path, chunk_size: int = 4 * 1024 * 1024) -> Generator[str]:
    buffer: str = ""

    with path.open("r", encoding="utf-8") as file:
        while chunk := file.read(chunk_size):
            *documents, buffer = (buffer + chunk).split(DOCUMENT_SEPARATOR)
            yield from (doc for document in documents if (doc := document.strip()))

        if doc := buffer.strip():
            yield doc
```

A file with no separator is a single document, which is what the documentation pages are.

Each document is assigned to training or validation by hashing its text:

```python
def is_validation(data: bytes) -> bool:
    digest = hashlib.blake2b(data, digest_size=8).digest()
    return int.from_bytes(digest, "big") / 2**64 < VALIDATION_RATIO
```

A good hash is uniform, so about five percent of documents fall below the threshold. Hence, the result depends only on the text. Adding a file or reordering the directory never moves a document across the split, and a document that appears twice in the corpus always stays on the same side, so it cannot leak from training into validation.

Each document's token ids, followed by `<eos>`, are appended to the `.bin` file for its side as raw `uint16`. Loading the dataset later is a single `np.fromfile`. The run over both sources produces:

| Source      | Training tokens | Validation tokens |
|-------------|----------------:|------------------:|
| tinystories |     512,190,998 |        27,073,001 |
| technical   |       2,227,268 |           125,545 |

## The model

The model is a decoder-only transformer, and MLX provides all of it as layers:

```python
class TinyLM(nn.Module):
    def __init__(self, vocab_size: int, num_layers: int, dims: int, num_heads: int) -> None:
        super().__init__()
        self.embedding = nn.Embedding(vocab_size, dims)
        self.position = nn.SinusoidalPositionalEncoding(dims)
        self.transformer = nn.TransformerEncoder(num_layers, dims, num_heads, norm_first=True)
        self.output = nn.Linear(dims, vocab_size, bias=False)

    def __call__(self, tokens: mx.array) -> mx.array:
        length = tokens.shape[1]
        mask = nn.MultiHeadAttention.create_additive_causal_mask(length)
        x = self.embedding(tokens) + self.position(mx.arange(length))
        x = self.transformer(x, mask)
        return self.output(x)
```

`TransformerEncoder` is used with a causal mask, which makes it a decoder. Each position can attend only to itself and the positions before it, so the prediction for position *n* cannot see token *n+1*. `norm_first=True` selects the pre-norm arrangement, which trains more stably at this scale without a warm-up schedule. The positional encoding is the fixed sinusoidal one rather than a learned table, which saves parameters and makes the context length a runtime argument rather than a shape.

With eight layers, 384 dimensions and six heads the model has about 26.8 million parameters. Nearly half of them are the embedding and the output projection, each a 16,384 by 384 matrix. The eight transformer layers together account for 14.2 million. The context is 256 tokens, which is enough for a whole TinyStories story.

## Training

The loss is cross-entropy between the logits at every position and the token that follows it. The input is the batch with its last token removed and the target is the batch with its first token removed:

```python
def loss_fn(model: TinyLM, batch: mx.array) -> mx.array:
    x = batch[:, :-1]
    y = batch[:, 1:]
    logits = model(x)
    return nn.losses.cross_entropy(logits, y, reduction="mean")
```

Sequences are therefore 257 tokens long, cut from the token stream without overlap. The optimiser is AdamW with a learning rate of 3e-4 and weight decay of 0.1, run for 20,000 steps at a batch of 16.

Four design points apply to the loop.

1. **Sample sources by weight**

    The technical source is 230 times smaller than TinyStories. Mixed in proportion to size it would be seen a few thousand times per run and leave no trace in the model. `config.py` gives each source a sampling weight instead:

    ```python
    SOURCE_WEIGHTS = {
        "tinystories": 0.75,
        "technical": 0.25,
    }
    ```

    Every batch draws its 16 sequences from the sources according to those weights. Each source has its own infinite stream that reshuffles when it runs out. Over a full run the model sees about 82 million tokens, so a quarter of that is roughly nine passes over the technical text and about a tenth of one pass over the stories. The weights are the knob that trades story fluency for technical vocabulary.

2. **Validate with the same weights**

    Validation loss is computed per source and printed per source, then combined with the same weights as the sampling. A single pooled validation set would be dominated by the large source and would not notice the small one being overfitted, which at nine epochs is the thing to watch. Reporting perplexity per source also shows the two are very different problems. Stories are far more predictable than documentation.

3. **Compile the step**

    The forward pass, the backward pass and the optimiser update are wrapped in one function and compiled:

    ```python
    @partial(mx.compile, inputs=state, outputs=state)
    def train_step(batch: mx.array) -> mx.array:
        loss, gradients = loss_and_grad(model, batch)
        optimizer.update(model, gradients)
        return loss
    ```

    MLX is lazy, so nothing runs until `mx.eval` is called on the state after each step. Compilation fuses the graph the first time it is traced and reuses it afterwards. The `inputs` and `outputs` arguments declare that the model and optimiser state are read and written by the function, which the tracer cannot see on its own.

4. **Stop early and keep the best**

    Every 500 steps the model is evaluated. If the weighted validation loss improved, the parameters are written to `checkpoints/best.safetensors`. If it has not improved for four evaluations in a row, training stops. The checkpoint on disk is therefore always the best one seen, and a run that goes on too long costs time but not quality. The model's shape is written alongside it as `config.json`, so `generate` needs nothing from `config.py`.

## Sampling

Generation is a loop that runs the model on the tokens so far, takes the logits for the last position, divides by the temperature and samples:

```python
for _ in range(max_tokens):
    context = tokens[:, -context_size:]
    logits = model(context)[:, -1, :] / temperature
    next_token = mx.reshape(mx.random.categorical(logits), (1, 1))
    if next_token.item() == eos_token_id:
        break
    tokens = mx.concatenate([tokens, next_token], axis=1)
```

The context is clipped to the model's window, so a long generation slides forward rather than overrunning the positional encoding. There is no key-value cache. At this size the whole context is recomputed on each step and it is still fast enough to read along with.

Temperature below one sharpens the distribution and produces safer, more repetitive text. Above one flattens it and the stories start to wander. The default is 0.8.

## Running it

From the project root, in order:

```bash
python -m tiny_llm.train_tokenizer
python -m tiny_llm.tokenize_dataset
python -m tiny_llm.train
python -m tiny_llm.generate "Once upon a time, there was a little dog named"
```

The first two are a one-off per corpus. Tokenizing prints its progress every ten seconds. Training prints the loss and the step rate every 50 steps, and the per-source validation figures every 500.

## Output

<!-- TODO before publishing: paste the total training time, the final per-source validation loss and perplexity, and a real sample. Then check the paragraph below against what the model actually produced. -->

The model was asked to continue a TinyStories prompt:

```bash
python -m tiny_llm.generate "Once upon a time, there was a little dog named"
```

And this is the text it produced:
```txt
Spot. Spot loved to play and run all day. One day, Spot saw a big, red ball. He wanted to play with it, but it was far away.
Spot asked his friend, a little girl named Lily, for help. "Did you lose my ball?" asked Spot. Lily said, "Yes, you can look at it and saw something even better." They both played with the ball and had lots of fun.
After playing for a while, Spot and Lily got tired. They lay down on the soft grass and ate their food. Spot was happy he had taken the ball to play with. Lily was happy too, because Spot was so grateful for her friend.
```

The stories have the general shape of the corpus. Characters are named, something is lost or feared, a friend helps, and the last sentence draws a moral. Sentences are grammatical and stay on topic for the length of the context. What the model does not have is any knowledge beyond the two sources, and a prompt outside them produces fluent text about nothing in particular.


The technical part though is just plan rubish at this point. Although it just had about 9.9MB of training material.

```bash
python -m tiny_llm.generate "Adding columns in a vaadin grid"
```

And this is one of the better outcomes where the text it produced is:
```txt
.css is automatically found, and sort the grid component.

[Java]
import com.vaadin.flow.component.grid.Grid;
import com.vaadin.flow.component.textfield.BigDecimal;
import com.vaadin.flow.data.renderer.LitRenderer;
import com.vaadin.flow.data.renderer.Renderer;
import com.vaadin.flow.router.Route;
import java.util.List;

@Route("grid-single-items")
public class GridRowReordering extends Div {

    @Override
    protected Div orders = new Div();

    public GridRowReordering() {
        // tag::snippet[]
        Grid<Person> grid = new Grid<>(Person.class, false);
        grid.addColumn(Person::getFirstName).setHeader("First name");
        grid.addColumn(Person::getLastName).setHeader("Last name");
```

Overall, a fun little project that helped me understand a little bit of the big picture. 

The project is about 700 lines of Python. The behaviour visible in the output is determined largely by the data and the sampling weights, and the code is the same for any corpus.
