# Wrapping a REST API in a MCP server

This post describes how to wrap an existing REST API in an MCP server, using an exchange-rate service as the example. [Frankfurter](https://frankfurter.dev) publishes daily reference rates from about a hundred central banks. It has a small and well-documented API, and it needs no API key.

It covers the Java code, the container image, and the client configuration for Claude Code. The finished project is at [github.com/cloudyhomelab/frankfurter-mcp](https://github.com/cloudyhomelab/frankfurter-mcp).

MCP itself is a small protocol built on JSON-RPC. A client such as Claude connects to a server and asks what tools it offers. The server answers with a list, and each entry carries a name, a description written for the model to read, and a JSON schema for the arguments. From then on the client calls those tools whenever the model decides one is needed, passing structured arguments and receiving structured results. Everything the server has to do follows from that exchange. It describes its tools accurately and it answers calls.

## The stack

The server is built on Java 21, Spring Boot 4.1 and Spring AI 2.0. Spring AI provides an MCP server starter that turns annotated methods into tools and implements the protocol, so the project has two runtime dependencies:

```xml
<dependency>
  <groupId>org.springframework.ai</groupId>
  <artifactId>spring-ai-starter-mcp-server-webmvc</artifactId>
</dependency>
<dependency>
  <groupId>org.springframework.boot</groupId>
  <artifactId>spring-boot-starter-restclient</artifactId>
</dependency>
```
The MCP starter brings a web server but not an HTTP client, so `RestClient` has to be added explicitly.

The code splits into two packages:

```
io.binarycodes.mcp.frankfurter:
  client    -   typed RestClient wrapper over the Frankfurter v2 API
  tools     -   @McpTool methods exposed to agents
```

The client package has no dependency on MCP and the tools package has no dependency on HTTP. The tools call the client, and the integration test replaces the client with a mock so the MCP layer can be exercised without network access.

## The API client

The client is a `RestClient` with a base URL and a `User-Agent` header, plus records for the response shapes:

```java
public record Rate(LocalDate date, String base, String quote, BigDecimal rate) { }
```

There is one method per endpoint. `rate` fetches a single pair and leaves out the optional query parameters when they are null, so the API applies its own defaults:

```java
public Rate rate(String base, String quote, LocalDate date, List<String> providers) {
    return http.get()
            .uri(uri -> {
                uri.path("/rate/{base}/{quote}");
                if (date != null) {
                    uri.queryParam("date", date.toString());
                }
                if (providers != null && !providers.isEmpty()) {
                    uri.queryParam("providers", String.join(",", providers));
                }
                return uri.build(base, quote);
            })
            .retrieve()
            .body(Rate.class);
}
```

The client bean registers a status handler for upstream errors. Frankfurter answers an unknown currency with HTTP 422 and a JSON body such as `{"message": "invalid currency: XXX"}`. The handler extracts the message and throws it as a `FrankfurterException`:

```java
.defaultStatusHandler(HttpStatusCode::isError, (request, response) -> {
    throw new FrankfurterException(response.getStatusCode().value(),
            errorMessage(response.getBody().readAllBytes(), mapper));
})
```

Spring AI converts any exception thrown from a tool method into an MCP tool error whose content is the exception message. The model therefore receives "invalid currency: XXX" and can correct its input.

## The tools

The tools package defines the nine tools. `get_rate` is representative:

```java
@McpTool(name = "get_rate",
        description = "Get the exchange rate for a single currency pair, latest or on a given date.",
        annotations = @McpAnnotations(readOnlyHint = true, destructiveHint = false, idempotentHint = true))
public Rate getRate(
        @McpToolParam(description = "Base currency code, e.g. EUR.") String base,
        @McpToolParam(description = "Quote currency code, e.g. USD.") String quote,
        @McpToolParam(description = "Date as YYYY-MM-DD. Omit for the latest rate.", required = false) String date,
        @McpToolParam(description = PROVIDERS_DESC, required = false) String providers) {
    return client.rate(Codes.one(base), Codes.one(quote), Codes.date(date, "date"), Codes.many(providers));
}
```

Spring AI reads the method signature and the annotations, builds the JSON schema, registers the tool, and deserialises incoming arguments into the parameters. The return value is serialised to JSON and returned as text content.

Four design points apply across the tools.

1. **The descriptions are the interface.**

    The model reads them once and decides from them which tool to call and how to fill in the arguments. "Date as YYYY-MM-DD" prevents arguments like "September 11th". "Omit for the latest rate" prevents `"date": "today"`. Descriptions should be revised against the arguments the model actually sends.


2. **Take strings, then normalise.**

    The model will send `usd`, `USD `, and `"USD, GBP"` for a comma-separated list. Rather than reject those, a small `Codes` class trims, upper-cases and splits on commas or whitespace. Dates are parsed with `LocalDate.parse`, and an invalid one throws an `IllegalArgumentException` whose message states the expected format. That message is returned to the model as the tool error.


3. **Do not mirror the API one-to-one.**

    Frankfurter has no conversion endpoint, only rates. Conversion is nevertheless the most common request, so `convert_currency` fetches the rate and performs the multiplication locally with `BigDecimal` and half-even rounding. Conversely, `get_time_series` requires the `quotes` argument although the API does not, because a year of daily rates for two hundred currencies is too large a response to place in a context window. `list_providers` returns a trimmed summary record instead of the full provider object for the same reason.


4. **Set the annotations.**

    `readOnlyHint`, `destructiveHint` and `idempotentHint` are advisory, but a client is allowed to use them to decide when to ask the user before a call. Every tool in this project is read-only, and the integration test asserts this.

## Configuration

`application.yml` picks the transport and gives the server a name and an instructions string:

```yaml
spring:
  ai:
    mcp:
      server:
        name: frankfurter
        version: 0.1.0
        type: SYNC
        protocol: STREAMABLE
        instructions: >-
          Exchange-rate tools backed by the Frankfurter API (frankfurter.dev). Rates are daily mid-market
          reference rates blended from central banks; they are not live trading prices. Currency codes are
          ISO 4217 (EUR, USD, ...). Dates are YYYY-MM-DD. For official figures, pass a provider such as ECB.
        capabilities:
          prompt: false
          resource: false
          completion: false
```

Here, `STREAMABLE` selects the Streamable HTTP transport, for remote servers. And `SYNC` means tool methods are plain blocking Java with no reactive types.

The `instructions` string is sent to the client during the handshake, and in clients such as Claude Code, it ends up in the model's context, so it is the place for things that apply to every tool, such as what the data is, what it is not, and what format codes take. The prompt, resource and completion capabilities are disabled because this server provides none of those.

There is a second profile for stdio, for clients that launch the server as a subprocess:

```yaml
---
spring:
  config:
    activate:
      on-profile: stdio
  main:
    web-application-type: none
    banner-mode: off
  ai:
    mcp:
      server:
        stdio: true
```

Under stdio the protocol owns stdout, and any log line written there corrupts the JSON-RPC stream. `logback-spring.xml` therefore routes the root logger to stderr under this profile, and the Spring banner is disabled. The same jar serves both transports.

## Testing it without the network

The client is unit-tested with `MockRestServiceServer` against canned responses. A second test drives the running server through the MCP Java SDK client:

```java
@SpringBootTest(webEnvironment = WebEnvironment.RANDOM_PORT)
class McpServerIntegrationTest {

    @LocalServerPort
    int port;
   
    @MockitoBean
    FrankfurterClient frankfurter;

    McpSyncClient mcp;

    @BeforeEach
    void connect() {
        mcp = McpClient.sync(HttpClientStreamableHttpTransport.builder("http://localhost:" + port).build()).build();
        mcp.initialize();
    }
```

With the upstream client mocked, it lists tools and checks the names and the read-only hints, calls `convert_currency` end to end and checks the rounded result. It throws a `FrankfurterException` from the mock to confirm it arrives as `isError: true` with the original message. The MCP Java SDK client is already on the classpath through the starter, so no additional test dependency is needed.

For manual checks, the official inspector works against the local server:

```bash
mvn package -DskipTests && java -jar target/frankfurter-mcp-0.1.0-SNAPSHOT.jar
npx @modelcontextprotocol/inspector
```

Connect it to `http://localhost:8080/mcp` with the Streamable HTTP transport to list and call the tools from a browser UI.

## The container

The project has a docker buildx configuration that creates the `frankfurter-mcp` container image. The image runs as a non-root user and has a `HEALTHCHECK` that does a plain GET on `/mcp`.

GitHub workflows are configured to run on pull requests and then when merged to `main`, it builds the multi-arch image and pushes it to Docker Hub.

## Adding it to Claude

For Claude Code, the server is registered from the command line:

```bash
claude mcp add --transport http frankfurter https://frankfurter-mcp.<domain>.<tld>/mcp
```

Then `/mcp` inside a session shows the server as connected and lists its nine tools. Adding `--scope user` to the command registers it for every project rather than only the current one.

For Claude Desktop and claude.ai, remote servers are added as a custom connector under Settings, Connectors, with the same URL. Claude Desktop can also launch the jar as a subprocess over stdio from `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "frankfurter": {
      "command": "java",
      "args": ["-jar", "/path/to/frankfurter-mcp-0.1.0-SNAPSHOT.jar", "--spring.profiles.active=stdio"]
    }
  }
}
```

## Using it

With the server connected, Claude was asked to convert 2500 euros to US dollars. It called `convert_currency` with `{"amount": 2500, "from": "EUR", "to": "USD"}` and received:

```json
{"amount":2500,"from":"EUR","to":"USD","date":"2026-09-14","rate":1.1599,"result":2899.7500}
```

A second request asked for the official ECB euro-dollar rate. The model called `get_rate` with `providers: "ECB"`, an argument it derived from the parameter description and the instructions string, and received:

```json
{"date":"2026-09-11","base":"EUR","quote":"USD","rate":1.1592}
```

The two figures differ in rate and in date. The first is the blended rate across all providers, published for the current day. The second is the ECB reference rate, whose most recent value is from the preceding Friday because the ECB does not publish on weekends. The model stated this when relaying the figure. It also noted that the rates are reference rates rather than live prices. That statement appears only in the `instructions` field, which the model received during the handshake.

The server is about 450 lines of Java, tests excluded. The behaviour visible in the conversation is determined largely by the text in the annotations and the instructions string.

## Applying this to another API

The pattern applies to any REST API with a small enough surface to wrap by hand or an existing client library:

1. Write a thin typed client. Records for responses, one method per endpoint, and an error handler that extracts the API's own error message into an exception.
2. Design the tools around the questions people ask, not around the endpoints. Add computed tools where the API lacks them. Force arguments that keep responses small.
3. Accept forgiving input and normalise it. Throw exceptions with messages written for the model to read.
4. Put everything that applies to every tool in `instructions`, and everything else in the parameter descriptions. Then observe what the model sends and revise.
5. Mock the client and test the MCP layer with the real SDK client. It catches schema and serialisation problems that unit tests on the tool methods miss.
6. Build the jar, wrap it in a container and let a reverse proxy handle TLS. Decide on authentication if required.

Adapting the repository to another API requires replacing the `client` package and rewriting the tools. The configuration, container, and CI carry over unchanged.
