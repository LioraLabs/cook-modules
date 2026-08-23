namespace Demo.Lib;

public static class Message
{
    private static string Detail => "v1";
    public static string Text => "hello " + Detail;
}
