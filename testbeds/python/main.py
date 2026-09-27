from calc import greet, total_length


def main() -> None:
    names = ["ann", "bob", "cy"]
    greetings = []
    for name in names:
        greeting = greet(name)
        greetings.append(greeting)
    total = total_length(names)
    print(f"{len(greetings)} greetings, {total} characters of names")


if __name__ == "__main__":
    main()
